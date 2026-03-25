#!/bin/bash
# =============================================================================
# build_rootfs.sh — базовый Debian rootfs (debootstrap + базовые пакеты)
# =============================================================================
set -e
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
source "${BUILD_DIR}/env"
OUT_DIR="${BUILD_DIR}/out"
mkdir -p "${OUT_DIR}"
source "${SCRIPTS_DIR}/common.sh"

[ "$(id -u)" = "0" ] || die "Запустите от root"

for cmd in debootstrap chroot qemu-arm-static; do
    command -v "${cmd}" &>/dev/null || die "Утилита не найдена: ${cmd}"
done

# KVER нужен для установки ядра
KVER=$(ls "${KERNEL_DIR}/rt-modules/lib/modules/" 2>/dev/null | head -1 || true)
[ -n "${KVER}" ] || die "Модули ядра не найдены — запустите build_kernel.sh"

# =============================================================================
# Шаг 1: debootstrap первый проход
# =============================================================================
log "Сборка базового Debian ${DEBIAN_SUITE} rootfs..."

if [ ! -f "${BASE_ROOTFS_DIR}/bin/bash" ]; then
    debootstrap \
        --arch=armhf \
        --foreign \
        "${DEBIAN_SUITE}" \
        "${BASE_ROOTFS_DIR}" \
        "${DEBIAN_MIRROR}"
else
    warn "Базовый rootfs уже существует, пропускаем debootstrap"
fi

cp /usr/bin/qemu-arm-static "${BASE_ROOTFS_DIR}/usr/bin/"

# Прокидываем resolv.conf хоста для работы DNS в chroot
# Удаляем симлинк если остался от предыдущей сборки
rm -f "${BASE_ROOTFS_DIR}/etc/resolv.conf"
cp /etc/resolv.conf "${BASE_ROOTFS_DIR}/etc/resolv.conf"

# =============================================================================
# Шаг 2: debootstrap второй проход + базовые пакеты
# =============================================================================
mount_virtfs "${BASE_ROOTFS_DIR}"

if [ -f "${BASE_ROOTFS_DIR}/debootstrap/debootstrap" ]; then
    chroot "${BASE_ROOTFS_DIR}" /debootstrap/debootstrap --second-stage
fi

# Базовые пакеты — всегда нужны для работы системы
chroot "${BASE_ROOTFS_DIR}" /bin/bash << CHROOT_EOF
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    sudo \
    systemd-sysv \
    iproute2 \
    openssh-server \
    parted \
    rsync \
    dosfstools \
    e2fsprogs \
    u-boot-tools \
    tcpdump \
    vim \
    traceroute \
    net-tools \
    gpiod \
    socat \
    ntp \
    ntpdate \
    linuxptp \
    ptpd

# Пользователи
echo "root:${ROOT_PASSWORD}" | chpasswd

if ! id ${USER_NAME} &>/dev/null; then
    useradd -m -s /bin/bash -G sudo ${USER_NAME}
else
    echo "Пользователь ${USER_NAME} уже существует, пропускаем"
fi
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME}
chmod 440 /etc/sudoers.d/${USER_NAME}
CHROOT_EOF

umount_virtfs "${BASE_ROOTFS_DIR}"

# =============================================================================
# Шаг 3: Ядро и модули
# =============================================================================
log "Установка ядра и модулей..."

mkdir -p "${BASE_ROOTFS_DIR}/boot"
cp "${KERNEL_DIR}/arch/arm/boot/zImage" \
    "${BASE_ROOTFS_DIR}/boot/vmlinuz-${KVER}"
cp "${KERNEL_DIR}/arch/arm/boot/dts/sun8i-h3-nanopi-neo-core.dtb" \
    "${BASE_ROOTFS_DIR}/boot/"

rm -rf "${BASE_ROOTFS_DIR}/lib/modules"
mkdir -p "${BASE_ROOTFS_DIR}/lib/modules"
cp -r "${KERNEL_DIR}/rt-modules/lib/modules/${KVER}" \
    "${BASE_ROOTFS_DIR}/lib/modules/${KVER}"
rm -f "${BASE_ROOTFS_DIR}/lib/modules/${KVER}/build"
rm -f "${BASE_ROOTFS_DIR}/lib/modules/${KVER}/source"

log "Модули установлены: ${KVER}"

# =============================================================================
# Шаг 4: Системные настройки
# =============================================================================
printf '/dev/mmcblk1p2\t/\text4\tdefaults,noatime\t0 1\n' \
    > "${BASE_ROOTFS_DIR}/etc/fstab"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "${DEVICE_HOSTNAME}" \
    > "${BASE_ROOTFS_DIR}/etc/hosts"
echo "${DEVICE_HOSTNAME}" > "${BASE_ROOTFS_DIR}/etc/hostname"

# =============================================================================
# Шаг 5: boot.scr
# =============================================================================
log "Создание boot.scr..."

cat > "${BASE_ROOTFS_DIR}/boot/boot.cmd" << EOF
setenv bootargs ${BOOTARGS_SD}
fatload mmc 0:1 0x42000000 vmlinuz-${KVER}
fatload mmc 0:1 0x43000000 sun8i-h3-nanopi-neo-core.dtb
bootz 0x42000000 - 0x43000000
EOF

mkimage -C none -A arm -T script \
    -d "${BASE_ROOTFS_DIR}/boot/boot.cmd" \
    "${BASE_ROOTFS_DIR}/boot/boot.scr"

mkimage -l "${BASE_ROOTFS_DIR}/boot/boot.scr" | grep -q "ARM Linux Script" \
    || die "boot.scr создан некорректно"

# =============================================================================
# Шаг 6: Оверлей (libs, bins, network, sources, packages, services)
# =============================================================================
apply_overlay "${BASE_ROOTFS_DIR}"

# =============================================================================
# Шаг 7: install-to-emmc.sh + systemd сервис
# =============================================================================
log "Установка install-to-emmc..."

INSTALL_SCRIPT="${SCRIPTS_DIR}/install-to-emmc.sh"
[ -f "${INSTALL_SCRIPT}" ] || die "install-to-emmc.sh не найден: ${INSTALL_SCRIPT}"

mkdir -p "${BASE_ROOTFS_DIR}/usr/local/bin"

# Подставляем bootargs из env при копировании
sed \
    -e "s|__BOOTARGS_SD__|${BOOTARGS_SD}|g" \
    -e "s|__BOOTARGS_EMMC__|${BOOTARGS_EMMC}|g" \
    "${INSTALL_SCRIPT}" \
    > "${BASE_ROOTFS_DIR}/usr/local/bin/install-to-emmc.sh"
chmod +x "${BASE_ROOTFS_DIR}/usr/local/bin/install-to-emmc.sh"

cat > "${BASE_ROOTFS_DIR}/etc/systemd/system/install-to-emmc.service" << 'SERVICE_EOF'
[Unit]
Description=Install system to eMMC on first boot from SD
After=local-fs.target
ConditionPathExists=!/etc/emmc-installed

[Service]
Type=oneshot
ExecStart=/usr/local/bin/install-to-emmc.sh
ExecStartPost=/bin/touch /etc/emmc-installed
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SERVICE_EOF

WANTS_DIR="${BASE_ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${WANTS_DIR}"
ln -sf /etc/systemd/system/install-to-emmc.service \
    "${WANTS_DIR}/install-to-emmc.service"

log "============================================"
log "Базовый rootfs готов: ${BASE_ROOTFS_DIR}"
log "  Ядро    : ${KVER}"
log "  boot.scr: готов"
log "============================================"
