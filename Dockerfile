FROM fedora:24

RUN dnf -y update && \
    dnf -y install net-tools libattr libattr-devel xfsprogs bridge-utils qemu-kvm qemu-system-x86 qemu-img gpg socat && \
    dnf clean all

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY qemu-ifup /etc/qemu-ifup
COPY qemu-shutdown /qemu-shutdown
COPY k8s-kvm /k8s-kvm
ENTRYPOINT ["/docker-entrypoint.sh"]
