#!/bin/bash
# =============================================================================
# install-to-emmc.sh
#
# Порядок важен:
#   1. parted размечает eMMC (пишет только MBR — сектор 0)
#   2. U-Boot копируется с SD ПОСЛЕ разметки
#      skip=16 seek=16 (offset 8192 байт = 8 KiB)
#      — именно там BROM Allwinner H3 ищет SPL
# =============================================================================
set -e

LOG=/var/log/install-to-emmc.log
exec > >(tee -a "${LOG}") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}==> $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
die()  { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

EMMC=/dev/mmcblk2
SD=/dev/mmcblk1
SD_BOOT="${SD}p1"

[ "$(id -u)" = "0" ] || die "Требуется root"

echo ""
echo "======================================================"
echo "  Установка системы на eMMC NanoPi NEO"
echo "  Дата: $(date)"
echo "======================================================"
echo ""

[ -b "${EMMC}" ]    || die "eMMC не найдена: ${EMMC}"
[ -b "${SD}" ]      || die "SD карта не найдена: ${SD}"
[ -b "${SD_BOOT}" ] || die "Boot-раздел SD не найден: ${SD_BOOT}"

KVER=$(ls /lib/modules/ | head -1)
[ -n "${KVER}" ] || die "Не удалось определить версию ядра"

log "eMMC : ${EMMC} ($(lsblk -dno SIZE ${EMMC}))"
log "SD   : ${SD}   ($(lsblk -dno SIZE ${SD}))"
log "Ядро : ${KVER}"
echo ""

cleanup() {
    umount /mnt/emmc-boot 2>/dev/null || true
    umount /mnt/emmc-root 2>/dev/null || true
    umount /mnt/sd-boot   2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# Шаг 1: Разметка eMMC
# parted пишет только MBR (сектор 0) — область с U-Boot (8KiB+) не затрагивается
# =============================================================================
log "Разметка eMMC..."

umount "${EMMC}p1" 2>/dev/null || true
umount "${EMMC}p2" 2>/dev/null || true

parted -s "${EMMC}" mklabel msdos
parted -s "${EMMC}" mkpart primary fat32  1MiB  257MiB
parted -s "${EMMC}" mkpart primary ext4  257MiB  100%

partprobe "${EMMC}" 2>/dev/null || true
sleep 2

# =============================================================================
# Шаг 2: U-Boot с SD → eMMC, ПОСЛЕ разметки
# =============================================================================
log "Записываем U-Boot с SD на eMMC (offset 8KiB)..."

dd if="${SD}" of="${EMMC}" bs=512 skip=16 seek=16 count=2048 conv=notrunc 2>/dev/null
sync

log "U-Boot записан"

# =============================================================================
# Шаг 3: Форматирование
# =============================================================================
log "Форматирование разделов eMMC..."
mkfs.vfat -F 32 -n BOOT  "${EMMC}p1"
mkfs.ext4 -F -L rootfs   "${EMMC}p2"

# =============================================================================
# Шаг 4: Монтирование
# =============================================================================
mkdir -p /mnt/emmc-boot /mnt/emmc-root /mnt/sd-boot

mount -t vfat -o iocharset=utf8 "${EMMC}p1"  /mnt/emmc-boot
mount                           "${EMMC}p2"  /mnt/emmc-root
mount -t vfat -o iocharset=utf8 "${SD_BOOT}" /mnt/sd-boot 2>/dev/null \
    || mount -t vfat            "${SD_BOOT}" /mnt/sd-boot

# =============================================================================
# Шаг 5: Загрузочные файлы
# =============================================================================
log "Копирование загрузочных файлов..."

[ -f "/mnt/sd-boot/vmlinuz-${KVER}" ] \
    || die "vmlinuz-${KVER} не найден в ${SD_BOOT}"
[ -f "/mnt/sd-boot/sun8i-h3-nanopi-neo-core.dtb" ] \
    || die "DTB не найден в ${SD_BOOT}"

cp "/mnt/sd-boot/vmlinuz-${KVER}"              /mnt/emmc-boot/
cp "/mnt/sd-boot/sun8i-h3-nanopi-neo-core.dtb" /mnt/emmc-boot/

# =============================================================================
# Шаг 6: boot.scr для eMMC
# =============================================================================
log "Создание boot.scr для eMMC..."

cat > /tmp/boot-emmc.cmd << BCMD
if fatload mmc 1:1 0x44000000 boot.scr; then
    echo "SD card detected - booting from SD..."
    fatload mmc 1:1 0x42000000 vmlinuz-${KVER}
    fatload mmc 1:1 0x43000000 sun8i-h3-nanopi-neo-core.dtb
    setenv bootargs __BOOTARGS_SD__
    bootz 0x42000000 - 0x43000000
fi
echo "No SD card - booting from eMMC..."
fatload mmc 0:1 0x42000000 vmlinuz-${KVER}
fatload mmc 0:1 0x43000000 sun8i-h3-nanopi-neo-core.dtb
setenv bootargs __BOOTARGS_EMMC__
bootz 0x42000000 - 0x43000000
BCMD

mkimage -C none -A arm -T script \
    -d /tmp/boot-emmc.cmd /mnt/emmc-boot/boot.scr

umount /mnt/sd-boot

# =============================================================================
# Шаг 7: Копирование rootfs
# =============================================================================
log "Копирование rootfs на eMMC (несколько минут)..."

rsync -aAX --info=progress2 \
    --exclude='/proc/*'     \
    --exclude='/sys/*'      \
    --exclude='/dev/*'      \
    --exclude='/run/*'      \
    --exclude='/tmp/*'      \
    --exclude='/mnt/*'      \
    --exclude='/var/log/install-to-emmc.log' \
    / /mnt/emmc-root/

# =============================================================================
# Шаг 8: Настройка eMMC rootfs
# =============================================================================
log "Настройка eMMC rootfs..."

printf '/dev/mmcblk2p2\t/\text4\tdefaults,noatime\t0 1\n' \
    > /mnt/emmc-root/etc/fstab

rm -f /mnt/emmc-root/etc/systemd/system/multi-user.target.wants/install-to-emmc.service
rm -f /mnt/emmc-root/etc/systemd/system/install-to-emmc.service
touch /mnt/emmc-root/etc/emmc-installed

sync

umount /mnt/emmc-boot
umount /mnt/emmc-root

echo ""
echo "======================================================"
log "Установка завершена: $(date)"
echo "======================================================"
echo ""
echo "  Лог : ${LOG}"
echo "  Извлеките SD карту и перезагрузите устройство"
echo ""
