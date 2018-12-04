FROM alpine:3.8

ARG COREOS_VERSION=1409.7.0
ARG FIRECRACKER_VERSION=0.11.0

RUN apk \
    --no-cache \
    add \
    bash=4.4.19-r1 \
    curl=7.61.1-r1

RUN curl \
    --location \
    https://github.com/firecracker-microvm/firecracker/releases/download/v$FIRECRACKER_VERSION/firecracker-v$FIRECRACKER_VERSION \
    --output \
    /firecracker

RUN curl \
    --location \
    http://stable.release.core-os.net/amd64-usr/$COREOS_VERSION/coreos_production_pxe.vmlinuz \
    --output \
    /vmlinuz

RUN curl \
    --location \
    http://stable.release.core-os.net/amd64-usr/$COREOS_VERSION/coreos_production_pxe_image.cpio.gz \
    --output \
    /rootfs

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
