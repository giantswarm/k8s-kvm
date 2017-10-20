FROM fedora:26

RUN dnf -y update && \
    dnf -y install net-tools libattr libattr-devel xfsprogs bridge-utils qemu-kvm  qemu-system-x86 qemu-img gpg && \
    dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
