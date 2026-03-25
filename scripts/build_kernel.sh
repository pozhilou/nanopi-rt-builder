#!/bin/bash
# =============================================================================
# build_kernel.sh — RT-патч, конфигурация, сборка ядра и модулей
# =============================================================================
set -e
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
source "${BUILD_DIR}/env"
OUT_DIR="${BUILD_DIR}/out"
mkdir -p "${OUT_DIR}"
source "${SCRIPTS_DIR}/common.sh"

[ "$(id -u)" = "0" ] || die "Запустите от root"

# =============================================================================
# Клонирование ядра (если KERNEL_CLONE=true)
# =============================================================================
if [ "${KERNEL_CLONE}" = "true" ]; then
    if [ ! -d "${KERNEL_DIR}/.git" ]; then
        log "Клонирование ядра Linux (${KERNEL_BRANCH})..."
        git clone "${KERNEL_REPO}" \
            -b "${KERNEL_BRANCH}" \
            --depth 1 \
            "${KERNEL_DIR}"
    else
        log "Исходники ядра уже есть: ${KERNEL_DIR}"
    fi
else
    log "KERNEL_CLONE=false — используем существующий ${KERNEL_DIR}"
fi

[ -d "${KERNEL_DIR}" ]          || die "Директория ядра не найдена: ${KERNEL_DIR}"
[ -f "${KERNEL_DIR}/Makefile" ] || die "Не похоже на исходники ядра: ${KERNEL_DIR}"

setup_toolchain

# Подавляем добавление git-суффикса к версии ядра
touch "${KERNEL_DIR}/.scmversion"

# =============================================================================
# Выбор тулчейна для ядра
# =============================================================================
if [ "${USE_FA_TOOLCHAIN}" = "true" ]; then
    if [ -d "${FA_TOOLCHAIN_DIR}" ]; then
        export PATH="${FA_TOOLCHAIN_DIR}:${PATH}"
        log "Тулчейн ядра: FriendlyARM (${FA_TOOLCHAIN_DIR})"
        log "  $(arm-linux-gcc --version 2>/dev/null | head -1 || echo 'не найден')"
        CROSS_COMPILE=${CROSS_COMPILE_FA}
    else
        warn "FriendlyARM тулчейн не найден: ${FA_TOOLCHAIN_DIR}"
        warn "Используем Linaro. Установите тулчейн или выключите USE_FA_TOOLCHAIN"
        CROSS_COMPILE=${CROSS_COMPILE_LINARO}
    fi
else
    log "Тулчейн ядра: Linaro (USE_FA_TOOLCHAIN=false)"
    CROSS_COMPILE=${CROSS_COMPILE_LINARO}
fi

# =============================================================================
# Шаг 1: RT-патч
# =============================================================================
cd "${KERNEL_DIR}"

if [ "${RT_PATCH_ENABLE}" = "true" ]; then
    log "Применение RT-патча..."
    if grep -rq "PREEMPT_RT_FULL" arch/arm/Kconfig init/Kconfig 2>/dev/null; then
        warn "RT-патч уже применён, пропускаем"
    else
        if [ ! -f "${RT_PATCH_FILE}" ]; then
            wget -q --show-progress "${RT_PATCH_URL}" -O "${RT_PATCH_FILE}.xz"
            unxz "${RT_PATCH_FILE}.xz"
        fi
        patch -p1 --force < "${RT_PATCH_FILE}" || true
        REJ_COUNT=$(find . -name "*.rej" | wc -l)
        [ "${REJ_COUNT}" -gt 0 ] && warn "Не применились фрагментов: ${REJ_COUNT}"
        grep -rq "PREEMPT_RT_FULL" arch/arm/Kconfig init/Kconfig \
            || die "RT не применился в Kconfig"
        log "RT-патч применён (отклонений: ${REJ_COUNT})"
    fi
else
    log "RT-патч: отключён (RT_PATCH_ENABLE=false)"
fi

KERNEL_VER=$(make kernelversion 2>/dev/null)
log "Версия ядра: ${KERNEL_VER}"

# =============================================================================
# Шаг 2: Конфигурация
# =============================================================================
log "Конфигурация ядра..."

# Удаляем старый .config чтобы не тащить устаревшие опции
rm -f .config

make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} sunxi_defconfig

# --- Первый проход: задаём нужные опции ---
if [ "${RT_PATCH_ENABLE}" = "true" ]; then
    scripts/config --disable CONFIG_PREEMPT_NONE
    scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
    scripts/config --disable CONFIG_PREEMPT
    scripts/config --disable CONFIG_PREEMPT_LAZY
    scripts/config --enable  CONFIG_PREEMPT_RT_FULL
fi

scripts/config --disable CONFIG_HZ_200
scripts/config --disable CONFIG_HZ_300
scripts/config --disable CONFIG_HZ_1000
scripts/config --enable  CONFIG_HZ_250

scripts/config --disable CONFIG_CRYPTO_SHA2_ARM_CE
scripts/config --disable CONFIG_CRYPTO_SHA1_ARM_CE
scripts/config --disable CONFIG_CRYPTO_AES_ARM_CE
scripts/config --disable CONFIG_CRYPTO_GHASH_ARM_CE
scripts/config --disable CONFIG_RAID6_PQ
scripts/config --disable CONFIG_KERNEL_MODE_NEON
scripts/config --disable CONFIG_VIDEO_OV5640
scripts/config --disable CONFIG_VDSO
scripts/config --disable CONFIG_DEBUG_PREEMPT

# --- olddefconfig может восстановить зависимые опции ---
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} olddefconfig

if [ "${RT_PATCH_ENABLE}" = "true" ]; then
    # --- Второй проход: принудительно отключаем то что olddefconfig мог включить ---
    scripts/config --disable CONFIG_PREEMPT_NONE
    scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
    scripts/config --disable CONFIG_PREEMPT
    scripts/config --disable CONFIG_PREEMPT_LAZY
fi

# --- Финальный olddefconfig чтобы разрешить зависимости ---
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} olddefconfig

# --- Строгая проверка конфига ---
log "Проверка конфигурации ядра..."

check_enabled()  { grep -q "^${1}=y"  .config || die "${1} должен быть включён, но не включён!"; }
check_disabled() { grep -q "^${1}="   .config && die "${1} должен быть выключен, но включён!"; true; }

if [ "${RT_PATCH_ENABLE}" = "true" ]; then
    check_enabled  CONFIG_PREEMPT_RT_FULL
    check_disabled CONFIG_PREEMPT_NONE
    check_disabled CONFIG_PREEMPT_VOLUNTARY
    check_disabled CONFIG_DEBUG_PREEMPT
    # PREEMPT_LAZY на ARM включается патчем через select HAVE_PREEMPT_LAZY — это нормально
fi

check_enabled  CONFIG_HZ_250

log "Конфигурация OK"
log "  PREEMPT_RT_FULL : $(grep CONFIG_PREEMPT_RT_FULL .config)"
log "  PREEMPT_LAZY    : $(grep CONFIG_PREEMPT_LAZY    .config || echo 'не установлен') (ARM RT-патч)"
log "  HZ              : $(grep 'CONFIG_HZ=' .config | grep -v HZ_)"

# =============================================================================
# Шаг 3: Сборка
# =============================================================================
log "Сборка ядра ($(nproc) потоков)..."
make -j$(nproc) ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} KCFLAGS="${KCFLAGS}" \
    2>&1 | tee /tmp/kernel_build.log

[ -f arch/arm/boot/zImage ] \
    || die "zImage не собрался, смотрите /tmp/kernel_build.log"
[ -f arch/arm/boot/dts/sun8i-h3-nanopi-neo-core.dtb ] \
    || die "DTB не собрался"

# =============================================================================
# Шаг 4: Модули
# =============================================================================
log "Сборка и установка модулей..."
make -j$(nproc) ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} KCFLAGS="${KCFLAGS}" modules

rm -rf "${KERNEL_DIR}/rt-modules"
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} \
    INSTALL_MOD_PATH="${KERNEL_DIR}/rt-modules" modules_install

KVER=$(ls "${KERNEL_DIR}/rt-modules/lib/modules/")
[ -n "${KVER}" ] || die "Не удалось определить версию модулей"

log "============================================"
log "Ядро собрано: ${KVER}"
log "============================================"
