#!/bin/bash

# The following parameters have to be given.
#
#     ${CORES}                  e.g. "1"
#     ${DISK}                   e.g. "4G"
#     ${HOSTNAME}               e.g. "kvm-master-1"
#     ${NETWORK_BRIDGE_NAME}    e.g. "br-h8s2l"
#     ${NETWORK_TAP_NAME}       e.g. "tap-h8s2l"
#     ${MEMORY}                 e.g. "2048"
#     ${ROLE}                   e.g. "master" or "worker"
#     ${CLOUD_CONFIG_PATH}      e.g. "/cloudconfig/user_data"
#     ${COREOS_VERSION}         e.g. "1409.7.0"

set -eu

raw_cloud_config_dir="/usr/code/cloudconfig/openstack/latest"
raw_cloud_config_path="${raw_cloud_config_dir}/user_data"

if [ -z ${CLOUD_CONFIG_PATH} ] || [ "${CLOUD_CONFIG_PATH}" == "${raw_cloud_config_path}" ]; then
    echo "CLOUD_CONFIG_PATH must be set, and must be different than '${raw_cloud_config_path}'. Got '${CLOUD_CONFIG_PATH}'." >&2
    exit 1
fi

#
# Find IP of network bridge.
#

NETWORK_BRIDGE_IP=""

while :; do
  NETWORK_BRIDGE_IP=$(/sbin/ifconfig ${NETWORK_BRIDGE_NAME} | grep 'inet ' | awk '{print $2}' | cut -d ':' -f 2)
  if [ ! -z "${NETWORK_BRIDGE_IP}" ]; then
    break
  fi
  echo "Waiting for ip address on interface ${NETWORK_BRIDGE_NAME}."
  sleep 1
done

echo "Found network bridge IP '${NETWORK_BRIDGE_IP}' for network bridge name '${NETWORK_BRIDGE_NAME}'."

#
# Enable the VM's network bridge.
#

echo "allow ${NETWORK_BRIDGE_NAME}" >/etc/qemu/bridge.conf

#
# Prepare FS.
#

mkdir -p /usr/code/rootfs/
mkdir -p /usr/code/cloudconfig/openstack/latest/

ROOTFS="/usr/code/rootfs/rootfs.img"
MAC_ADDRESS=$(printf 'DE:AD:BE:%02X:%02X:%02X\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))


#
# Prepare CoreOS images.
#

IMGDIR="/usr/code/images"
KERNEL="${IMGDIR}/coreos_production_qemu.vmlinuz"
USRFS="${IMGDIR}/coreos_production_qemu_usr_image.squashfs"

mkdir -p ${IMGDIR}

# Use specific CoreOS version, if ${COREOS_VERSION} is set and not empty.
# Check if images already in place, if not download them.
if [ ! -z ${COREOS_VERSION+x} ] && [ ! -z "${COREOS_VERSION}" ]; then
  KERNEL="${IMGDIR}/${COREOS_VERSION}/coreos_production_qemu.vmlinuz"
  USRFS="${IMGDIR}/${COREOS_VERSION}/coreos_production_qemu_usr_image.squashfs"

  # Download if does not exist.
  if [ ! -f "${IMGDIR}/${COREOS_VERSION}/done.lock" ]; then

    # Prepare directory for images.
    rm -rf ${IMGDIR}/${COREOS_VERSION}
    mkdir -p ${IMGDIR}/${COREOS_VERSION}; cd ${IMGDIR}/${COREOS_VERSION}

    # Download images.
    curl --fail -O http://stable.release.core-os.net/amd64-usr/${COREOS_VERSION}/coreos_production_pxe.vmlinuz
    curl --fail -O http://stable.release.core-os.net/amd64-usr/${COREOS_VERSION}/coreos_production_pxe_image.cpio.gz

    # Check the signatures after download.
    # XXX: Assume local storage is trusted, do not check everytime pod starts.
    curl --fail -s https://coreos.com/security/image-signing-key/CoreOS_Image_Signing_Key.asc | gpg --import -
    curl --fail -O http://stable.release.core-os.net/amd64-usr/${COREOS_VERSION}/coreos_production_pxe.vmlinuz.sig
    curl --fail -O http://stable.release.core-os.net/amd64-usr/${COREOS_VERSION}/coreos_production_pxe_image.cpio.gz.sig
    gpg --verify coreos_production_pxe.vmlinuz.sig
    gpg --verify coreos_production_pxe_image.cpio.gz.sig

    # Extract squashfs.
    zcat coreos_production_pxe_image.cpio.gz | cpio -i --quiet --sparse usr.squashfs && mv usr.squashfs $USRFS

    # Do cleanup.
    rm -f coreos_production_pxe_image.cpio.gz
    rm -f coreos_production_pxe.vmlinuz.sig
    rm -f coreos_production_pxe_image.cpio.gz.sig

    # Create lock.
    touch done.lock; cd -
  fi
fi

#
# Prepare root FS.
#

rm -f $ROOTFS
truncate -s ${DISK} $ROOTFS
mkfs.xfs $ROOTFS

#
# Ensure proper mounts.
#

ETCD_DATA_VOLUME_PATH=""

if [ "$ROLE" = "master" ]; then
  ETCD_DATA_VOLUME_PATH="-fsdev local,security_model=none,id=fsdev1,path=/etc/kubernetes/data/etcd/ -device virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=etcdshare"
fi

# Pin the vm on a certain CPU. Make sure the variable is set and a CPU value is
# given.

TASKSET=

if [ ! -z ${PIN_CPU+x} ] && [ ! -z "$PIN_CPU" ]; then
  TASKSET="taskset -ac $PIN_CPU"
fi

#
# Boot the VM.
#

mkdir -p "${raw_cloud_config_dir}"
cat "${CLOUD_CONFIG_PATH}" | base64 -d | gunzip > "${raw_cloud_config_path}"
echo "hostname: '${HOSTNAME}'" >> "${raw_cloud_config_path}"

exec $TASKSET /usr/bin/qemu-system-x86_64 \
  -name ${HOSTNAME} \
  -nographic \
  -machine accel=kvm \
  -cpu host,pmu=off \
  -smp ${CORES} \
  -m ${MEMORY} \
  -enable-kvm \
  -device virtio-net-pci,netdev=${NETWORK_TAP_NAME} \
  -netdev tap,id=${NETWORK_TAP_NAME},br=${NETWORK_BRIDGE_NAME},ifname=${NETWORK_TAP_NAME},downscript=no \
  -fsdev local,id=conf,security_model=none,readonly,path=/usr/code/cloudconfig \
  -device virtio-9p-pci,drive=conf,serial=config-2 \
  $ETCD_DATA_VOLUME_PATH \
  -drive if=virtio,cache=none,file=$USRFS,format=raw,serial=usr.readonly \
  -drive if=virtio,cache=none,file=$ROOTFS,format=raw,discard=on,serial=rootfs \
  -device sga \
  -serial mon:stdio \
  -kernel \
  $KERNEL \
  -append "console=ttyS0 root=/dev/sdb rootflags=rw mount.usr=/dev/sda mount.usrflags=ro"
