#!/bin/bash
# =============================================================================
# build_image.sh — создание образа диска (.img.gz) для Balena Etcher
#
# Порядок записи U-Boot (критично для загрузки):
#   1. dd нули     — создаём пустой файл образа
#   2. parted      — размечаем (пишет только MBR, сектор 0)
#   3. dd U-Boot   — записываем SPL+u-boot с offset 8KiB (bs=1024 seek=8)
#                    ПОСЛЕ parted, чтобы parted не затёр U-Boot
#   4. mkfs        — форматируем разделы через loop (не трогают offset <1MiB)
# =============================================================================
set -e
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
source "${BUILD_DIR}/env"
OUT_DIR="${BUILD_DIR}/out"
mkdir -p "${OUT_DIR}"
source "${SCRIPTS_DIR}/common.sh"

ROOTFS_DIR="${BASE_ROOTFS_DIR}"

[ "$(id -u)" = "0" ]        || die "Запустите от root"
[ -f "${UBOOT_BIN}" ]        || die "U-Boot не найден: ${UBOOT_BIN}"
[ -d "${ROOTFS_DIR}" ]       || die "Rootfs не найден: ${ROOTFS_DIR}"
[ -f "${ROOTFS_DIR}/boot/boot.scr" ] || die "boot.scr не найден в ${ROOTFS_DIR}/boot/"

KVER=$(ls "${KERNEL_DIR}/rt-modules/lib/modules/" 2>/dev/null | head -1 || true)
[ -n "${KVER}" ] || die "Модули ядра не найдены"

log "Rootfs  : ${ROOTFS_DIR}"
log "Ядро    : ${KVER}"
log "U-Boot  : ${UBOOT_BIN} ($(ls -lh ${UBOOT_BIN} | awk '{print $5}'))"

for cmd in parted mkfs.vfat mkfs.ext4 losetup rsync gzip mkimage; do
    command -v "${cmd}" &>/dev/null || die "Утилита не найдена: ${cmd}"
done

# --- loop-устройства ---
for i in $(seq 0 7); do
    [ -b /dev/loop${i} ] || mknod /dev/loop${i} b 7 ${i}
done

LOOP_BOOT=""
LOOP_ROOT=""

cleanup_image() {
    umount "${OUT_DIR}/mnt/boot"   2>/dev/null || true
    umount "${OUT_DIR}/mnt/rootfs" 2>/dev/null || true
    [ -n "${LOOP_BOOT}" ] && losetup -d "${LOOP_BOOT}" 2>/dev/null || true
    [ -n "${LOOP_ROOT}" ] && losetup -d "${LOOP_ROOT}" 2>/dev/null || true
}
trap cleanup_image EXIT

# =============================================================================
# Параметры образа
# =============================================================================
IMAGES_DIR="${OUT_DIR}/images"
mkdir -p "${IMAGES_DIR}"

IMG_FILE="${IMAGES_DIR}/nanopi-rt-${KVER}.img"
IMG_GZ="${IMG_FILE}.gz"

BOOT_START_MB=1
BOOT_SIZE_MB=256
ROOT_START_MB=$(( BOOT_START_MB + BOOT_SIZE_MB ))

# Убеждаемся что виртуальные ФС размонтированы перед созданием образа
umount_virtfs "${ROOTFS_DIR}"

ROOTFS_SIZE_MB=$(du -sm \
    --exclude="${ROOTFS_DIR}/proc" \
    --exclude="${ROOTFS_DIR}/sys" \
    --exclude="${ROOTFS_DIR}/dev" \
    --exclude="${ROOTFS_DIR}/run" \
    --exclude="${ROOTFS_DIR}/tmp" \
    "${ROOTFS_DIR}" | awk '{print $1}')
ROOTFS_SIZE_MB=$(( ROOTFS_SIZE_MB + 512 ))
TOTAL_SIZE_MB=$(( ROOT_START_MB + ROOTFS_SIZE_MB ))

log "Размер rootfs: ${ROOTFS_SIZE_MB} МБ, итого образ: ${TOTAL_SIZE_MB} МБ"

# =============================================================================
# Шаг 1: Создание пустого образа
# =============================================================================
log "Создание образа диска..."
rm -f "${IMG_FILE}"
dd if=/dev/zero of="${IMG_FILE}" bs=1M count="${TOTAL_SIZE_MB}" status=progress

# =============================================================================
# Шаг 2: Разметка (parted пишет только MBR — сектор 0)
# =============================================================================
log "Разметка образа..."
parted -s "${IMG_FILE}" mklabel msdos
parted -s "${IMG_FILE}" mkpart primary fat32 "${BOOT_START_MB}MiB" "${ROOT_START_MB}MiB"
parted -s "${IMG_FILE}" mkpart primary ext4  "${ROOT_START_MB}MiB" 100%

# =============================================================================
# Шаг 3: Запись U-Boot ПОСЛЕ разметки
# bs=1024 seek=8 → offset 8192 байт (8 KiB) — именно туда смотрит BROM H3
# conv=notrunc — не затираем MBR который записал parted
# =============================================================================
log "Записываем U-Boot в образ (offset 8KiB)..."
dd if="${UBOOT_BIN}" of="${IMG_FILE}" bs=1024 seek=8 conv=notrunc 2>/dev/null
sync
log "U-Boot записан"

# =============================================================================
# Шаг 4: Форматирование разделов через loop
# loop монтируется с offset≥1MiB — зона U-Boot (8KiB–1MiB) не затрагивается
# =============================================================================
BOOT_OFFSET=$(( BOOT_START_MB * 1024 * 1024 ))
BOOT_SIZE=$(( BOOT_SIZE_MB * 1024 * 1024 ))
ROOT_OFFSET=$(( ROOT_START_MB * 1024 * 1024 ))
ROOT_SIZE=$(( ROOTFS_SIZE_MB * 1024 * 1024 ))

LOOP_BOOT=$(losetup --find --show \
    --offset "${BOOT_OFFSET}" --sizelimit "${BOOT_SIZE}" "${IMG_FILE}")
LOOP_ROOT=$(losetup --find --show \
    --offset "${ROOT_OFFSET}" --sizelimit "${ROOT_SIZE}" "${IMG_FILE}")

log "Loop boot: ${LOOP_BOOT}"
log "Loop root: ${LOOP_ROOT}"

mkfs.vfat -F 32 -n BOOT  "${LOOP_BOOT}"
mkfs.ext4 -F -L rootfs   "${LOOP_ROOT}"

# =============================================================================
# Шаг 5: Заполнение образа
# =============================================================================
mkdir -p "${OUT_DIR}/mnt/boot" "${OUT_DIR}/mnt/rootfs"
mount -t vfat -o iocharset=utf8 "${LOOP_BOOT}" "${OUT_DIR}/mnt/boot"
mount                           "${LOOP_ROOT}"  "${OUT_DIR}/mnt/rootfs"

cp "${ROOTFS_DIR}/boot/vmlinuz-${KVER}"              "${OUT_DIR}/mnt/boot/"
cp "${ROOTFS_DIR}/boot/sun8i-h3-nanopi-neo-core.dtb" "${OUT_DIR}/mnt/boot/"
cp "${ROOTFS_DIR}/boot/boot.scr"                     "${OUT_DIR}/mnt/boot/"

log "Копирование rootfs в образ (несколько минут)..."
rsync -aAX \
    --exclude='/boot/*'  \
    --exclude='/proc/*'  \
    --exclude='/sys/*'   \
    --exclude='/dev/*'   \
    --exclude='/run/*'   \
    --exclude='/tmp/*'   \
    "${ROOTFS_DIR}/" "${OUT_DIR}/mnt/rootfs/"

sync

umount "${OUT_DIR}/mnt/boot"
umount "${OUT_DIR}/mnt/rootfs"
losetup -d "${LOOP_BOOT}"; LOOP_BOOT=""
losetup -d "${LOOP_ROOT}"; LOOP_ROOT=""

# =============================================================================
# Шаг 6: Сжатие
# =============================================================================
log "Сжатие образа..."
rm -f "${IMG_GZ}"
gzip -1 --stdout "${IMG_FILE}" > "${IMG_GZ}"
rm -f "${IMG_FILE}"

IMG_SIZE=$(du -sh "${IMG_GZ}" | awk '{print $1}')

log "============================================"
log "Образ готов!"
log "  Файл    : ${IMG_GZ} (${IMG_SIZE})"
log "  Ядро    : ${KVER}"
log "============================================"
echo ""
echo "  1. Запишите образ через Balena Etcher на SD карту >= $(( TOTAL_SIZE_MB / 1024 + 1 )) ГБ"
echo "  2. Вставьте SD в NanoPi и включите питание"
echo "  3. Система установится на eMMC автоматически"
echo "  4. Извлеките SD и перезагрузите"
echo ""
