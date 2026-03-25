#!/bin/bash
# =============================================================================
# build_uboot.sh — сборка или копирование U-Boot
#
# Управляется через env:
#   UBOOT_BUILD=true   — клонировать и собрать из исходников
#   UBOOT_BUILD=false  — скопировать готовый из UBOOT_PREBUILT
#
# Результат всегда: ${UBOOT_BIN} — финальный путь откуда берёт build_image.sh
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
# Режим: копирование готового бинаря
# =============================================================================
if [ "${UBOOT_BUILD}" != "true" ]; then
    log "U-Boot: сборка отключена (UBOOT_BUILD=false)"
    log "Копируем готовый U-Boot из ${UBOOT_PREBUILT}..."

    [ -f "${UBOOT_PREBUILT}" ] \
        || die "Готовый U-Boot не найден: ${UBOOT_PREBUILT}\nПоложите файл туда или включите UBOOT_BUILD=true"

    mkdir -p "$(dirname "${UBOOT_BIN}")"
    if [ "$(realpath "${UBOOT_PREBUILT}")" != "$(realpath "${UBOOT_BIN}" 2>/dev/null)" ]; then
        cp "${UBOOT_PREBUILT}" "${UBOOT_BIN}"
        log "U-Boot скопирован: ${UBOOT_BIN} ($(ls -lh ${UBOOT_BIN} | awk '{print $5}'))"
    else
        log "UBOOT_PREBUILT совпадает с UBOOT_BIN — копирование не нужно"
        log "U-Boot: ${UBOOT_BIN} ($(ls -lh ${UBOOT_BIN} | awk '{print $5}'))"
    fi
    exit 0
fi

# =============================================================================
# Режим: сборка из исходников
# =============================================================================
log "U-Boot: сборка из исходников (UBOOT_BUILD=true)"

# --- Тулчейн ---
setup_toolchain

# =============================================================================
# Выбор тулчейна для U-Boot
# =============================================================================
if [ "${UBOOT_USE_FA_TOOLCHAIN}" = "true" ]; then
    if [ -d "${FA_TOOLCHAIN_DIR}" ]; then
        export PATH="${FA_TOOLCHAIN_DIR}:${PATH}"
        log "Тулчейн U-Boot: FriendlyARM (${FA_TOOLCHAIN_DIR})"
        log "  $(arm-linux-gcc --version 2>/dev/null | head -1 || echo 'не найден')"
        UBOOT_CROSS=${CROSS_COMPILE_FA}
    else
        warn "FriendlyARM тулчейн не найден: ${FA_TOOLCHAIN_DIR}"
        warn "Используем Linaro. Установите тулчейн или выключите UBOOT_USE_FA_TOOLCHAIN"
        UBOOT_CROSS=${CROSS_COMPILE_LINARO}
    fi
else
    log "Тулчейн U-Boot: Linaro (UBOOT_USE_FA_TOOLCHAIN=false)"
    UBOOT_CROSS=${CROSS_COMPILE_LINARO}
fi

# --- Клонирование ---
if [ ! -d "${UBOOT_DIR}/.git" ]; then
    log "Клонирование U-Boot (${UBOOT_BRANCH})..."
    git clone "${UBOOT_REPO}" \
        -b "${UBOOT_BRANCH}" \
        --depth 1 \
        "${UBOOT_DIR}"
else
    log "Исходники U-Boot уже есть: ${UBOOT_DIR}"
fi

cd "${UBOOT_DIR}"

# Подавляем добавление git-суффикса к версии U-Boot
touch .scmversion

# --- Конфигурация ---
log "Конфигурация: nanopi_h3_defconfig..."
make nanopi_h3_defconfig \
    ARCH=arm \
    CROSS_COMPILE=${UBOOT_CROSS}

# --- Сборка ---
log "Сборка U-Boot ($(nproc) потоков)..."
make -j$(nproc) \
    ARCH=arm \
    CROSS_COMPILE=${UBOOT_CROSS}

# --- Проверка результата ---
[ -f "${UBOOT_DIR}/u-boot-sunxi-with-spl.bin" ] \
    || die "u-boot-sunxi-with-spl.bin не собрался"

# --- Копируем в финальное место ---
mkdir -p "$(dirname "${UBOOT_BIN}")"
if [ "$(realpath "${UBOOT_DIR}/u-boot-sunxi-with-spl.bin")" != "$(realpath "${UBOOT_BIN}" 2>/dev/null)" ]; then
    cp "${UBOOT_DIR}/u-boot-sunxi-with-spl.bin" "${UBOOT_BIN}"
else
    log "UBOOT_DIR совпадает с UBOOT_BIN — копирование не нужно"
fi

log "============================================"
log "U-Boot собран: ${UBOOT_BIN} ($(ls -lh ${UBOOT_BIN} | awk '{print $5}'))"
log "============================================"
