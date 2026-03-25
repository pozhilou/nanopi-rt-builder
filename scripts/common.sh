#!/bin/bash
# =============================================================================
# common.sh — вспомогательные функции
# Переменные конфигурации — в env.sh
#
# Использование в скриптах из scripts/:
#   SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
#   BUILD_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
#   source "${SCRIPTS_DIR}/common.sh"
# =============================================================================

# =============================================================================
# Цвета и логирование
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==> $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
die()  { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# =============================================================================
# Монтирование виртуальных ФС для chroot
# =============================================================================
mount_virtfs() {
    local rdir="${1}"
    mount -t proc   proc    "${rdir}/proc"    2>/dev/null || true
    mount -t sysfs  sysfs   "${rdir}/sys"     2>/dev/null || true
    mount -o bind   /dev    "${rdir}/dev"     2>/dev/null || true
    mount -t devpts devpts  "${rdir}/dev/pts" 2>/dev/null || true
}

umount_virtfs() {
    local rdir="${1}"
    umount "${rdir}/dev/pts" 2>/dev/null || true
    umount "${rdir}/dev"     2>/dev/null || true
    umount "${rdir}/proc"    2>/dev/null || true
    umount "${rdir}/sys"     2>/dev/null || true
}

# =============================================================================
# Тулчейн Linaro GCC 4.9
# =============================================================================
setup_toolchain() {
    local gcc_ver
    gcc_ver=$(arm-linux-gnueabihf-gcc --version 2>/dev/null | head -1 || true)

    if ! echo "${gcc_ver}" | grep -q "4\.9"; then
        warn "GCC 4.9 не найден в PATH, устанавливаем Linaro 4.9..."
        local linaro_dir="${BUILD_DIR}/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf"
        if [ ! -d "${linaro_dir}" ]; then
            wget -q --show-progress \
                https://releases.linaro.org/components/toolchain/binaries/4.9-2017.01/arm-linux-gnueabihf/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf.tar.xz \
                -O "${BUILD_DIR}/gcc-linaro.tar.xz"
            tar xf "${BUILD_DIR}/gcc-linaro.tar.xz" -C "${BUILD_DIR}"
            rm "${BUILD_DIR}/gcc-linaro.tar.xz"
        fi
        export PATH="${linaro_dir}/bin:${PATH}"
    fi

    arm-linux-gnueabihf-gcc --version | head -1
    log "Тулчейн OK"
}

# =============================================================================
# apply_overlay — наложение оверлея на rootfs
#
# Структура оверлея (всё относительно BUILD_DIR):
#   libs/            → /usr/local/lib/          + ldconfig
#   bins/            → /usr/local/bin/          + chmod +x
#   network/         → /etc/systemd/network/    + включает systemd-networkd
#   sources/         → /etc/apt/sources.list.d/ (каждый файл отдельно)
#   packages/*.list  → устанавливает пакеты через apt
#   services/*.service → /etc/systemd/system/  + systemctl enable
# =============================================================================
apply_overlay() {
    local target_dir="${1}"

    [ -d "${target_dir}" ] || die "Целевой rootfs не найден: ${target_dir}"

    log "Наложение оверлея на ${target_dir}..."

    # Проверка наличия реальных файлов (игнорируем .gitkeep)
    has_files() {
        local dir="${1}"
        [ -d "${dir}" ] || return 1
        find "${dir}" -maxdepth 1 -type f ! -name ".gitkeep" | grep -q .
    }

    # --- libs/ ---
    if has_files "${OVERLAY_LIBS}"; then
        log "  libs/ → /usr/local/lib/"
        mkdir -p "${target_dir}/usr/local/lib"
        find "${OVERLAY_LIBS}" -maxdepth 1 -type f ! -name ".gitkeep" \
            -exec cp -v {} "${target_dir}/usr/local/lib/" \;
        mount_virtfs "${target_dir}"
        chroot "${target_dir}" ldconfig
        umount_virtfs "${target_dir}"
    else
        warn "  libs/ — пусто, пропускаем"
    fi

    # --- bins/ ---
    if has_files "${OVERLAY_BINS}"; then
        log "  bins/ → /usr/local/bin/"
        mkdir -p "${target_dir}/usr/local/bin"
        find "${OVERLAY_BINS}" -maxdepth 1 -type f ! -name ".gitkeep" \
            -exec cp -v {} "${target_dir}/usr/local/bin/" \;
        chmod +x "${target_dir}/usr/local/bin/"*
    else
        warn "  bins/ — пусто, пропускаем"
    fi

    # --- network/ ---
    if has_files "${OVERLAY_NETWORK}"; then
        log "  network/ → /etc/systemd/network/ + systemd-networkd"
        mkdir -p "${target_dir}/etc/systemd/network"
        find "${OVERLAY_NETWORK}" -maxdepth 1 -type f ! -name ".gitkeep" \
            -exec cp -v {} "${target_dir}/etc/systemd/network/" \;
        rm -f "${target_dir}/etc/network/interfaces"
        ln -sf /run/systemd/resolve/stub-resolv.conf \
            "${target_dir}/etc/resolv.conf" 2>/dev/null || true
        mount_virtfs "${target_dir}"
        chroot "${target_dir}" /bin/bash << 'NEOF'
systemctl disable networking    2>/dev/null || true
systemctl enable  systemd-networkd
systemctl enable  systemd-resolved
NEOF
        umount_virtfs "${target_dir}"
    else
        warn "  network/ — пусто, пропускаем (сеть не настроена)"
    fi

    # --- sources/ → /etc/apt/sources.list.d/ ---
    if has_files "${OVERLAY_SOURCES}"; then
        log "  sources/ → /etc/apt/sources.list.d/"
        mkdir -p "${target_dir}/etc/apt/sources.list.d"
        find "${OVERLAY_SOURCES}" -maxdepth 1 -type f ! -name ".gitkeep" \
            -exec cp -v {} "${target_dir}/etc/apt/sources.list.d/" \;
        # Очищаем стандартный sources.list чтобы избежать дублей
        > "${target_dir}/etc/apt/sources.list"
        log "  /etc/apt/sources.list очищен (используем sources.list.d/)"
    else
        warn "  sources/ — пусто, пропускаем"
    fi

    # --- packages/*.list → apt install ---
    if [ -d "${OVERLAY_PACKAGES}" ] && \
       [ -n "$(find "${OVERLAY_PACKAGES}" -maxdepth 1 -name "*.list" ! -name ".gitkeep" 2>/dev/null)" ]; then
        log "  packages/*.list → устанавливаем пакеты..."
        PACKAGES=$(find "${OVERLAY_PACKAGES}" -maxdepth 1 -name "*.list" ! -name ".gitkeep" \
            -exec cat {} \; \
            | grep -v '^\s*#' \
            | grep -v '^\s*$' \
            | sort -u \
            | tr '\n' ' ')
        if [ -n "${PACKAGES}" ]; then
            rm -f "${target_dir}/etc/resolv.conf"
            cp /etc/resolv.conf "${target_dir}/etc/resolv.conf"
            mount_virtfs "${target_dir}"
            chroot "${target_dir}" /bin/bash << PKGEOF
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${PACKAGES}
PKGEOF
            umount_virtfs "${target_dir}"
            if has_files "${OVERLAY_NETWORK}"; then
                ln -sf /run/systemd/resolve/stub-resolv.conf \
                    "${target_dir}/etc/resolv.conf" 2>/dev/null || true
            else
                rm -f "${target_dir}/etc/resolv.conf"
            fi
            log "  Пакеты установлены"
        else
            warn "  packages/*.list — файлы пустые, пропускаем"
        fi
    else
        warn "  packages/ — нет .list файлов, пропускаем"
    fi

    # --- services/*.service → /etc/systemd/system/ + enable ---
    if [ -d "${OVERLAY_SERVICES}" ] && \
       [ -n "$(find "${OVERLAY_SERVICES}" -maxdepth 1 -name "*.service" 2>/dev/null)" ]; then
        log "  services/ → /etc/systemd/system/ + enable"
        mkdir -p "${target_dir}/etc/systemd/system"
        mount_virtfs "${target_dir}"
        for svc_file in "${OVERLAY_SERVICES}/"*.service; do
            [ -f "${svc_file}" ] || continue
            svc_name=$(basename "${svc_file}")
            cp "${svc_file}" "${target_dir}/etc/systemd/system/${svc_name}"
            chroot "${target_dir}" systemctl enable "${svc_name}"
            log "    enabled: ${svc_name}"
        done
        umount_virtfs "${target_dir}"
    else
        warn "  services/ — пусто, пропускаем"
    fi

    log "Оверлей наложен"
}
