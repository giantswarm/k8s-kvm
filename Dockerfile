FROM fedora:29

RUN dnf -y update && \
    dnf -y install \
        bridge-utils-1.6-2.fc29 \
        gnupg-1.4.23-2.fc29 \
        iproute-4.20.0-1.fc29 \
        libattr-2.4.48-3.fc29 \
        libattr-devel-2.4.48-3.fc29 \
        net-tools-2.0-0.53.20160912git.fc29 \
        qemu-img-3.0.0-4.fc29 \
        qemu-kvm-3.0.0-4.fc29 \
        qemu-system-x86-3.0.0-4.fc29 \
        socat-1.7.3.2-7.fc29 \
        xfsprogs-4.17.0-3.fc29 \
    && dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY qemu-ifup /etc/qemu-ifup
COPY qemu-shutdown /qemu-shutdown
COPY qemu-node-setup /qemu-node-setup
ENTRYPOINT ["/docker-entrypoint.sh"]
