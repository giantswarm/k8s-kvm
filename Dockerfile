FROM fedora:30

RUN dnf -y update && \
    dnf -y install \
        bridge-utils-1.6-3.fc30 \
        e2fsprogs-1.44.6-1.fc30 \
        gnupg2-2.2.13-1.fc30 \
        iproute-5.0.0-2.fc30 \
        libattr-2.4.48-5.fc30 \
        libattr-devel-2.4.48-5.fc30 \
        net-tools-2.0-0.54.20160912git.fc30 \
        qemu-img-3.1.0-6.fc30 \
        qemu-kvm-3.1.0-6.fc30 \
        qemu-system-x86-3.1.0-6.fc30 \
        socat-1.7.3.2-9.fc30 \
        xfsprogs-4.19.0-4.fc30 \
    && dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY qemu-ifup /etc/qemu-ifup
COPY qemu-shutdown /qemu-shutdown
COPY qemu-node-setup /qemu-node-setup
ENTRYPOINT ["/docker-entrypoint.sh"]
