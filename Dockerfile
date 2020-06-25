FROM fedora:33

RUN dnf -y update && \
    dnf -y install \
        bridge-utils \
        gnupg \
        iproute \
        libattr \
        libattr-devel \
        net-tools \
        qemu-img \
        qemu-kvm \
        qemu-system-x86 \
        socat \
        xfsprogs \
    && dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY qemu-ifup /etc/qemu-ifup
COPY qemu-shutdown /qemu-shutdown
COPY qemu-node-setup /qemu-node-setup
ENTRYPOINT ["/docker-entrypoint.sh"]
