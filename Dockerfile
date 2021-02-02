FROM fedora:33 AS builder

# Please keep this list sorted alphabetically
ENV PACKAGES \
    bc \
    brlapi-devel \
    bzip2 \
    bzip2-devel \
    capstone-devel \
    ccache \
    clang \
    cyrus-sasl-devel \
    dbus-daemon \
    device-mapper-multipath-devel \
    diffutils \
    findutils \
    gcc \
    gcc-c++ \
    genisoimage \
    gettext \
    git \
    glib2-devel \
    glusterfs-api-devel \
    gnutls-devel \
    gtk3-devel \
    hostname \
    libaio-devel \
    libasan \
    libattr-devel \
    libblockdev-mpath-devel \
    libcap-ng-devel \
    libcurl-devel \
    libepoxy-devel \
    libfdt-devel \
    libiscsi-devel \
    libjpeg-devel \
    libpmem-devel \
    libpng-devel \
    librbd-devel \
    libseccomp-devel \
    libslirp-devel \
    libssh-devel \
    libubsan \
    libudev-devel \
    libusbx-devel \
    libxml2-devel \
    libzstd-devel \
    llvm \
    lzo-devel \
    make \
    meson \
    mingw32-bzip2 \
    mingw32-curl \
    mingw32-glib2 \
    mingw32-gmp \
    mingw32-gnutls \
    mingw32-gtk3 \
    mingw32-libjpeg-turbo \
    mingw32-libpng \
    mingw32-libtasn1 \
    mingw32-nettle \
    mingw32-nsis \
    mingw32-pixman \
    mingw32-pkg-config \
    mingw32-SDL2 \
    mingw64-bzip2 \
    mingw64-curl \
    mingw64-glib2 \
    mingw64-gmp \
    mingw64-gnutls \
    mingw64-gtk3 \
    mingw64-libjpeg-turbo \
    mingw64-libpng \
    mingw64-libtasn1 \
    mingw64-nettle \
    mingw64-pixman \
    mingw64-pkg-config \
    mingw64-SDL2 \
    nmap-ncat \
    ncurses-devel \
    nettle-devel \
    ninja-build \
    nss-devel \
    numactl-devel \
    perl \
    perl-Test-Harness \
    pixman-devel \
    python3 \
    python3-PyYAML \
    python3-numpy \
    python3-opencv \
    python3-pillow \
    python3-pip \
    python3-sphinx \
    python3-virtualenv \
    rdma-core-devel \
    SDL2-devel \
    snappy-devel \
    sparse \
    spice-server-devel \
    systemd-devel \
    systemtap-sdt-devel \
    tar \
    tesseract \
    tesseract-langpack-eng \
    usbredir-devel \
    virglrenderer-devel \
    vte291-devel \
    which \
    xen-devel \
    zlib-devel \
    xz
ENV FEATURES mingw clang pyyaml asan docs
ENV PATH $PATH:/usr/libexec/python3-sphinx/
ENV QEMU_VERSION 5.2.0
# Build QEMU only for x86_64 devices
ENV QEMU_TARGET_LIST x86_64-softmmu
ENV QEMU_CONFIGURE_OPTS --python=/usr/bin/python3
# make install will copy files into this location
ENV QEMU_INSTALL_PREFIX /usr/local/qemu-"$QEMU_VERSION"

RUN dnf install -y $PACKAGES \
    && rpm -q $PACKAGES | sort > /packages.txt \
    && curl -fsSLO --compressed "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" \
    && tar -xf "qemu-$QEMU_VERSION.tar.xz" \
    && cd "qemu-$QEMU_VERSION" \
    && ./configure \
        --prefix="$QEMU_INSTALL_PREFIX" \
        --enable-werror \
        --disable-gcrypt \
        --enable-nettle \
        --enable-docs \
        --enable-fdt=system \
        --enable-slirp=system \
        --enable-capstone=system \
        --target-list="$QEMU_TARGET_LIST" || { cat config.log && exit 1; } \
    && make -j$(getconf _NPROCESSORS_ONLN) \
    && make install

FROM fedora:33

ENV QEMU_VERSION 5.2.0
ENV QEMU_INSTALL_PREFIX /usr/local/qemu-"$QEMU_VERSION"

RUN dnf -y update \
    && dnf -y install \
        bridge-utils \
        brlapi \
        gnupg \
        iproute \
        librbd1 \
        libaio \
        libpmem \
        libslirp \
        libcacard \
        libattr \
        libattr-devel \
        libfdt \
        libiscsi \
        librados2 \
        libgfapi0 \
        lzo \
        net-tools \
        numactl-libs \
        python3-capstone \
        SDL2 \
        snappy \
        spice-server \
        socat \
        usbredir \
        virglrenderer \
        vte291 \
        xfsprogs \
        xen-libs \
    && dnf clean all

COPY --from=builder $QEMU_INSTALL_PREFIX /usr/local

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY qemu-ifup /etc/qemu-ifup
COPY qemu-shutdown /qemu-shutdown
COPY qemu-node-setup /qemu-node-setup

# Smoke tests
RUN qemu-system-x86_64 --version

ENTRYPOINT ["/docker-entrypoint.sh"]
