FROM fedora:23

RUN dnf -y update && \
    dnf install -y net-tools libattr libattr-devel xfsprogs bridge-utils qemu-kvm  qemu-system-x86 qemu-img && \
    dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
