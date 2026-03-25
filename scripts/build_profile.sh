#!/bin/bash
# =============================================================================
# build_profile.sh — профильный rootfs (клон базового + конфиги профиля)
#
# Использование: ./build_profile.sh --back | --front
# =============================================================================
set -e
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
source "${BUILD_DIR}/env"
OUT_DIR="${BUILD_DIR}/out"
mkdir -p "${OUT_DIR}"
source "${SCRIPTS_DIR}/common.sh"

# Разбор профиля (только --back / --front, не --base)
PROFILE=""
for arg in "$@"; do
    case "${arg}" in
        --back)  PROFILE="back"  ;;
        --front) PROFILE="front" ;;
        *) die "Использование: $0 --back|--front" ;;
    esac
done
[ -n "${PROFILE}" ] || die "Использование: $0 --back|--front"

ROOTFS_DIR="${OUT_DIR}/debian-root-${PROFILE}"
DEVICE_HOSTNAME="${DEVICE_HOSTNAME}-${PROFILE}"
CONFIG_DIR="${BUILD_DIR}/config_passport/TEM7A/515/vbk/${PROFILE}"

[ "$(id -u)" = "0" ] || die "Запустите от root"
[ -f "${BASE_ROOTFS_DIR}/bin/bash" ] \
    || die "Базовый rootfs не найден, запустите build_rootfs.sh"

KVER=$(ls "${KERNEL_DIR}/rt-modules/lib/modules/" 2>/dev/null | head -1 || true)
[ -n "${KVER}" ] || die "Модули ядра не найдены"

log "Профиль : ${PROFILE}"
log "Rootfs  : ${ROOTFS_DIR}"
log "Конфиги : ${CONFIG_DIR}"

# =============================================================================
# Шаг 1: Клонируем базовый rootfs в профильный
# =============================================================================
log "Клонирование базового rootfs → ${ROOTFS_DIR}..."
[ -d "${ROOTFS_DIR}" ] && { warn "Пересоздаём профильный rootfs..."; rm -rf "${ROOTFS_DIR}"; }
cp -a "${BASE_ROOTFS_DIR}" "${ROOTFS_DIR}"

echo "${DEVICE_HOSTNAME}" > "${ROOTFS_DIR}/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "${DEVICE_HOSTNAME}" \
    > "${ROOTFS_DIR}/etc/hosts"

# =============================================================================
# Шаг 2: Наложение конфигов профиля (etc/ home/ lib/)
# =============================================================================
if [ -d "${CONFIG_DIR}" ]; then
    log "Наложение конфигов профиля ${PROFILE}..."
    [ -d "${CONFIG_DIR}/etc"  ] && cp -rv "${CONFIG_DIR}/etc/."  "${ROOTFS_DIR}/etc/"
    [ -d "${CONFIG_DIR}/home" ] && { cp -rv "${CONFIG_DIR}/home/." "${ROOTFS_DIR}/home/"; \
        find "${ROOTFS_DIR}/home" -name "*.sh" -exec chmod +x {} \;; }
    [ -d "${CONFIG_DIR}/lib"  ] && cp -rv "${CONFIG_DIR}/lib/."  "${ROOTFS_DIR}/lib/"
else
    warn "Директория конфигов не найдена: ${CONFIG_DIR}, пропускаем"
fi

# =============================================================================
# Шаг 3: Включение сервисов из конфигов профиля
# =============================================================================
WANTS_DIR="${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${WANTS_DIR}"

for svc in "${ROOTFS_DIR}/etc/systemd/system/"*.service; do
    [ -f "${svc}" ] || continue
    svc_name=$(basename "${svc}")
    [ "${svc_name}" = "install-to-emmc.service" ] && continue
    ln -sf "/etc/systemd/system/${svc_name}" "${WANTS_DIR}/${svc_name}" 2>/dev/null || true
    log "  enabled: ${svc_name}"
done

for tmr in "${ROOTFS_DIR}/etc/systemd/system/"*.timer; do
    [ -f "${tmr}" ] || continue
    tmr_name=$(basename "${tmr}")
    ln -sf "/etc/systemd/system/${tmr_name}" "${WANTS_DIR}/${tmr_name}" 2>/dev/null || true
    log "  enabled: ${tmr_name}"
done

for svc in "${ROOTFS_DIR}/lib/systemd/system/"*.service; do
    [ -f "${svc}" ] || continue
    svc_name=$(basename "${svc}")
    ln -sf "/lib/systemd/system/${svc_name}" "${WANTS_DIR}/${svc_name}" 2>/dev/null || true
    log "  enabled (lib): ${svc_name}"
done

# =============================================================================
# Шаг 4: gpio-netdev сервис
# =============================================================================
log "Создание gpio-netdev.service..."

cat > "${ROOTFS_DIR}/etc/systemd/system/gpio-netdev.service" << 'SERVICE_EOF'
[Unit]
Description=Enable GPIO netdev LEDs and mSATA power
After=local-fs.target
Before=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '/home/gpio_init.sh'
TimeoutSec=4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

ln -sf /etc/systemd/system/gpio-netdev.service "${WANTS_DIR}/gpio-netdev.service"

if [ ! -f "${ROOTFS_DIR}/home/gpio_init.sh" ]; then
    GPIO_INIT="${OVERLAY_DIR}/files/gpio_init.sh"
    [ -f "${GPIO_INIT}" ] || die "gpio_init.sh не найден: ${GPIO_INIT}"
    cp "${GPIO_INIT}" "${ROOTFS_DIR}/home/gpio_init.sh"
    log "gpio_init.sh скопирован из scripts/files/"
else
    log "gpio_init.sh взят из профиля"
fi
chmod +x "${ROOTFS_DIR}/home/gpio_init.sh"

# =============================================================================
# Шаг 5: install-to-emmc сервис (наследуется из базового rootfs — уже есть)
# =============================================================================
ln -sf /etc/systemd/system/install-to-emmc.service \
    "${WANTS_DIR}/install-to-emmc.service" 2>/dev/null || true

log "============================================"
log "Профиль ${PROFILE} готов: ${ROOTFS_DIR}"
log "============================================"
