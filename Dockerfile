FROM fedora:29

RUN dnf -y update && \
    dnf -y install net-tools libattr libattr-devel xfsprogs bridge-utils qemu-kvm qemu-system-x86 qemu-img gpg socat iproute && \
    dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY start.sh /start.sh
COPY qemu-ifup /etc/qemu-ifup
COPY qemu-shutdown /qemu-shutdown
COPY qemu-node-setup /qemu-node-setup
ENTRYPOINT ["/docker-entrypoint.sh"]
