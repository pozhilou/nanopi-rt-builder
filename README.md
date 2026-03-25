# nanopi-rt-builder

Сборочная система для создания образов **Debian Bullseye** с **RT-ядром Linux 4.14** для [NanoPi NEO](https://wiki.friendlyelec.com/wiki/index.php/NanoPi_NEO) (Allwinner H3).

Собирает готовый `.img.gz` для записи на SD карту через Balena Etcher. При первой загрузке система автоматически устанавливается на eMMC.

---

## Возможности

- RT-ядро Linux 4.14 с патчем PREEMPT_RT
- U-Boot — сборка из исходников или готовый бинарь
- Debian Bullseye (armhf) через debootstrap
- Автоматическая установка на eMMC при первой загрузке с SD
- Гибкий оверлей: добавляйте пакеты, сервисы, сетевые конфиги, библиотеки и бинари просто помещая файлы в нужные папки
- Все параметры в одном файле `env`

---

## Требования

- Docker
- FriendlyARM тулчейн: `arm-cortexa9-linux-gnueabihf-4.9.3-20160512.tar.xz` (положить рядом с `Dockerfile`)

---

## Быстрый старт

```bash
# 1. Собрать Docker-образ сборочного окружения
docker build -t nanopi-rt-builder .

# 2. Запустить контейнер
docker run --rm -it --privileged \
    -v $(pwd):/build \
    nanopi-rt-builder

# 3. Внутри контейнера — запустить сборку
cd /build
./build.sh
```

Готовый образ появится в `out/images/nanopi-rt-<kver>.img.gz`.

---

## Структура проекта

```
nanopi-rt-builder/
├── build.sh              # единственная точка входа
├── env                   # все параметры сборки
├── Dockerfile            # сборочное окружение
│
├── scripts/              # скрипты сборки (не редактировать)
│   ├── build_uboot.sh
│   ├── build_kernel.sh
│   ├── build_rootfs.sh
│   ├── build_image.sh
│   ├── install-to-emmc.sh
│   └── common.sh
│
├── overlay/              # файлы накладываемые на целевую систему
│   ├── bins/             # → /usr/local/bin/ (chmod +x)
│   ├── libs/             # → /usr/local/lib/ (ldconfig)
│   ├── network/          # → /etc/systemd/network/ (*.network файлы)
│   ├── packages/         # пакеты для apt (*.list, один пакет на строку)
│   ├── sources/          # → /etc/apt/sources.list.d/ (*.list файлы)
│   └── services/         # → /etc/systemd/system/ (*.service + enable)
│
├── src/                  # исходники (создаются при сборке или вручную)
│   ├── linux_kernel/     # исходники ядра Linux
│   └── uboot/            # исходники или готовый u-boot-sunxi-with-spl.bin
│
└── out/                  # результаты сборки (создаётся автоматически)
    ├── debian-root-base/ # собранный rootfs
    ├── mnt/              # точки монтирования (временные)
    └── images/           # готовые образы *.img.gz
```

---

## Конфигурация

Все параметры находятся в файле `env`. Основные:

### Пользователи

```bash
ROOT_PASSWORD="pass"
USER_NAME="user"
USER_PASSWORD="pass"
```

### U-Boot

```bash
UBOOT_BUILD=false          # false — использовать готовый бинарь из src/uboot/
                           # true  — собрать из исходников
UBOOT_REPO="https://github.com/friendlyarm/u-boot.git"
UBOOT_BRANCH="sunxi-v2017.x"
```

При `UBOOT_BUILD=false` положите готовый бинарь в `src/uboot/u-boot-sunxi-with-spl.bin`.

### Ядро Linux

```bash
KERNEL_CLONE=false         # false — использовать существующий src/linux_kernel/
                           # true  — клонировать из KERNEL_REPO
KERNEL_REPO="https://github.com/friendlyarm/linux.git"
KERNEL_BRANCH="sunxi-4.14.y"
```

### RT-патч

```bash
RT_PATCH_ENABLE=true       # true  — применить PREEMPT_RT патч
                           # false — собрать стандартное ядро
```

### Тулчейн

```bash
USE_FA_TOOLCHAIN=true      # true  — FriendlyARM arm-linux- (рекомендуется)
                           # false — Linaro arm-linux-gnueabihf-
```

### Сеть

Положите файл `*.network` в `overlay/network/` — systemd-networkd включится автоматически.

```ini
# overlay/network/01-eth0.network
[Match]
Name=eth0

[Network]
Address=192.168.1.10/24
Gateway=192.168.1.1
DNS=8.8.8.8
```

### Дополнительные пакеты

```bash
# overlay/packages/extra.list
htop
iperf3
python3
```

---

## Флаги пропуска шагов

Для отладки отдельных шагов:

```bash
./build.sh --skip-uboot    # пропустить U-Boot
./build.sh --skip-kernel   # пропустить сборку ядра
./build.sh --skip-rootfs   # пропустить сборку rootfs
./build.sh --skip-image    # пропустить создание образа
```

Комбинировать:

```bash
# Пересобрать только образ (ядро и rootfs уже готовы)
./build.sh --skip-uboot --skip-kernel --skip-rootfs
```

---

## Прошивка и установка

1. Запишите `out/images/nanopi-rt-<kver>.img.gz` на SD карту через [Balena Etcher](https://www.balena.io/etcher/)
2. Вставьте SD карту в NanoPi NEO и включите питание
3. Система автоматически установится на eMMC (лог: `/var/log/install-to-emmc.log`)
4. После завершения установки извлеките SD карту и перезагрузите устройство
5. При повторной вставке SD карта будет иметь приоритет при загрузке

---

## Железо

| Параметр     | Значение                        |
|--------------|---------------------------------|
| Плата        | NanoPi NEO / NEO Core           |
| SoC          | Allwinner H3 (Cortex-A7, 4 ядра) |
| ОЗУ          | 256 МБ / 512 МБ                 |
| eMMC         | /dev/mmcblk2                    |
| SD карта     | /dev/mmcblk1                    |
| UART         | ttyS0, 115200                   |

---

## Лицензия

MIT
