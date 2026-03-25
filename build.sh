#!/bin/bash
# =============================================================================
# build.sh — единственная точка входа сборки
#
# Использование:
#   ./build.sh               # сборка образа → .img.gz
#
# Флаги пропуска (для отладки отдельных шагов):
#   --skip-uboot     пропустить сборку/копирование U-Boot
#   --skip-kernel    пропустить сборку ядра
#   --skip-rootfs    пропустить сборку базового rootfs
#   --skip-image     пропустить создание образа
#
# Структура проекта:
#   build.sh          ← вы здесь
#   env               ← переменные конфигурации
#   scripts/          ← скрипты сборки
#   overlay/          ← файлы накладываемые на систему
#   src/              ← исходники (linux_kernel, uboot)
#   out/              ← создаётся при сборке (rootfs, images)
# =============================================================================

set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${BUILD_DIR}/scripts"
OUT_DIR="${BUILD_DIR}/out"

[ -d "${SCRIPTS_DIR}" ] || { echo "[ERROR] scripts/ не найдена: ${SCRIPTS_DIR}"; exit 1; }

source "${BUILD_DIR}/env"
source "${SCRIPTS_DIR}/common.sh"

# =============================================================================
# Разбор аргументов
# =============================================================================
SKIP_UBOOT=0
SKIP_KERNEL=0
SKIP_ROOTFS=0
SKIP_IMAGE=0

for arg in "$@"; do
    case "${arg}" in
        --skip-uboot)   SKIP_UBOOT=1   ;;
        --skip-kernel)  SKIP_KERNEL=1  ;;
        --skip-rootfs)  SKIP_ROOTFS=1  ;;
        --skip-image)   SKIP_IMAGE=1   ;;
        *)
            die "Неизвестный аргумент: ${arg}\nИспользование: $0 [--skip-uboot] [--skip-kernel] [--skip-rootfs] [--skip-image]"
            ;;
    esac
done

[ "$(id -u)" = "0" ] || die "Запустите от root"

mkdir -p "${OUT_DIR}"

# =============================================================================
# Шапка
# =============================================================================
echo ""
echo "=========================================="
echo "  NanoPi NEO RT — сборка образа"
echo "  BUILD_DIR : ${BUILD_DIR}"
echo "  Hostname  : ${DEVICE_HOSTNAME}"
echo "=========================================="
echo "  Шаги:"
echo "    [0] u-boot  : $([ ${SKIP_UBOOT}  = 1 ] && echo 'ПРОПУСК' || echo "ДА (build=${UBOOT_BUILD})")"
echo "    [1] ядро    : $([ ${SKIP_KERNEL} = 1 ] && echo 'ПРОПУСК' || echo "ДА (RT=${RT_PATCH_ENABLE})")"
echo "    [2] rootfs  : $([ ${SKIP_ROOTFS} = 1 ] && echo 'ПРОПУСК' || echo 'ДА')"
echo "    [3] образ   : $([ ${SKIP_IMAGE}  = 1 ] && echo 'ПРОПУСК' || echo 'ДА')"
echo "=========================================="
echo ""

# =============================================================================
# Шаг 0: U-Boot
# =============================================================================
if [ "${SKIP_UBOOT}" = "0" ]; then
    echo ">>> [0/3] build_uboot.sh"
    bash "${SCRIPTS_DIR}/build_uboot.sh"
else
    echo ">>> [0/3] build_uboot.sh — ПРОПУЩЕН"
fi

# =============================================================================
# Шаг 1: Ядро
# =============================================================================
if [ "${SKIP_KERNEL}" = "0" ]; then
    echo ""
    echo ">>> [1/3] build_kernel.sh"
    bash "${SCRIPTS_DIR}/build_kernel.sh"
else
    echo ">>> [1/3] build_kernel.sh — ПРОПУЩЕН"
fi

# =============================================================================
# Шаг 2: Rootfs
# =============================================================================
if [ "${SKIP_ROOTFS}" = "0" ]; then
    echo ""
    echo ">>> [2/3] build_rootfs.sh"
    bash "${SCRIPTS_DIR}/build_rootfs.sh"
else
    echo ">>> [2/3] build_rootfs.sh — ПРОПУЩЕН"
fi

# =============================================================================
# Шаг 3: Образ диска
# =============================================================================
if [ "${SKIP_IMAGE}" = "0" ]; then
    echo ""
    echo ">>> [3/3] build_image.sh"
    bash "${SCRIPTS_DIR}/build_image.sh"
else
    echo ">>> [3/3] build_image.sh — ПРОПУЩЕН"
fi

# =============================================================================
# Итог
# =============================================================================
KVER=$(ls "${KERNEL_DIR}/rt-modules/lib/modules/" 2>/dev/null | head -1 || echo "?")
IMG_GZ="${OUT_DIR}/images/nanopi-rt-${KVER}.img.gz"

echo ""
echo "=========================================="
echo "  Сборка завершена!"
echo "  Ядро  : ${KVER}"
[ "${SKIP_IMAGE}" = "0" ] && echo "  Образ : ${IMG_GZ}"
echo "=========================================="
