FROM debian:stretch

RUN echo "deb http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security stretch/updates main" >> /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build essentials
    build-essential \
    gcc \
    make \
    bc \
    # System cross-compilers for U-Boot (GCC 6.3)
    gcc-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu \
    # Kernel build dependencies
    libssl-dev \
    libelf-dev \
    bison \
    flex \
    kmod \
    udev \
    ssh \
    # U-Boot build dependencies
    swig \
    python \
    python-dev \
    python3-dev \
    device-tree-compiler \
    # Disk image tools
    parted \
    dosfstools \
    e2fsprogs \
    util-linux \
    rsync \
    gzip \
    # QEMU for chroot into armhf/arm64 rootfs
    qemu-user-static \
    # Rootfs bootstrap
    debootstrap \
    # U-Boot script compiler
    u-boot-tools \
    # Misc
    wget \
    xz-utils \
    bzip2 \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Linaro 4.9 — для сборки ядра Linux
# =============================================================================
ARG LINARO_BASE=https://releases.linaro.org/components/toolchain/binaries/4.9-2017.01

RUN wget -q --show-progress \
        ${LINARO_BASE}/arm-linux-gnueabihf/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf.tar.xz \
        -O /tmp/linaro-arm.tar.xz && \
    tar xf /tmp/linaro-arm.tar.xz -C /opt && \
    rm /tmp/linaro-arm.tar.xz

RUN wget -q --show-progress \
        ${LINARO_BASE}/aarch64-linux-gnu/gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu.tar.xz \
        -O /tmp/linaro-aarch64.tar.xz && \
    tar xf /tmp/linaro-aarch64.tar.xz -C /opt && \
    rm /tmp/linaro-aarch64.tar.xz

# =============================================================================
# FriendlyARM 4.9.3 — для сборки U-Boot (рекомендован производителем)
# Префикс: arm-linux-  (arm-linux-gcc, arm-linux-objcopy и т.д.)
# =============================================================================
COPY arm-cortexa9-linux-gnueabihf-4.9.3-20160512.tar.xz /tmp/fa-arm.tar.xz
RUN mkdir -p /opt/FriendlyARM/toolchain && \
    tar xf /tmp/fa-arm.tar.xz -C /opt/FriendlyARM/toolchain && \
    rm /tmp/fa-arm.tar.xz

ENV PATH="/opt/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf/bin:\
/opt/gcc-linaro-4.9.4-2017.01-x86_64_aarch64-linux-gnu/bin:\
/opt/FriendlyARM/toolchain/4.9.3/bin:\
${PATH}"

# =============================================================================
# dtc — свежая версия (нужна для ядра)
# =============================================================================
RUN git clone https://github.com/dgibson/dtc.git /tmp/dtc && \
    cd /tmp/dtc && \
    git checkout v1.5.0 && \
    make -j$(nproc) NO_YAML=1 && \
    make install PREFIX=/usr/local NO_YAML=1 && \
    rm -f /usr/local/include/libfdt*.h \
          /usr/local/lib/libfdt*.a \
          /usr/local/lib/libfdt*.so* && \
    rm -rf /tmp/dtc

ENV PATH="/usr/local/bin:${PATH}"

# =============================================================================
# Проверка окружения
# =============================================================================
RUN echo "=== Build environment ===" && \
    gcc --version | head -1 && \
    arm-linux-gnueabihf-gcc --version | head -1 && \
    arm-linux-gcc --version | head -1 && \
    aarch64-linux-gnu-gcc --version | head -1 && \
    python --version && \
    dtc --version && \
    make --version | head -1

WORKDIR /build
CMD ["/bin/bash"]
