#!/bin/bash

# The following parameters have to be given.
#
#     ${CORES}                  e.g. "1"
#     ${DISK}                   e.g. "4G"
#     ${HOSTNAME}               e.g. "kvm-master-1"
#     ${NETWORK_BRIDGE_NAME}    e.g. "br-h8s2l"
#     ${MEMORY}                 e.g. "2048"
#     ${ROLE}                   e.g. "master" or "worker"
#     ${CLOUD_CONFIG_PATH}      e.g. "/cloudconfig/user_data"

set -eu

RAW_CLOUD_CONFIG_DIR="/usr/code/cloudconfig/openstack/latest"
RAW_CLOUD_CONFIG_PATH="${RAW_CLOUD_CONFIG_DIR}/user_data"

if [ -z ${CLOUD_CONFIG_PATH} ] || [ "${CLOUD_CONFIG_PATH}" == "${RAW_CLOUD_CONFIG_PATH}" ]; then
    echo "CLOUD_CONFIG_PATH must be set, and must be different than '${RAW_CLOUD_CONFIG_PATH}'. Got '${CLOUD_CONFIG_PATH}'." >&2
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
mkdir -p /usr/code/images/
mkdir -p /usr/code/cloudconfig/openstack/latest/

ROOTFS="/usr/code/rootfs/rootfs.img"
KERNEL="/usr/code/images/coreos_production_qemu.vmlinuz"
USRFS="/usr/code/images/coreos_production_qemu_usr_image.squashfs"
MAC_ADDRESS=$(printf 'DE:AD:BE:%02X:%02X:%02X\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))

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

mkdir -p "${RAW_CLOUD_CONFIG_DIR}"
cat "${CLOUD_CONFIG_PATH}" | base64 -d | gunzip > "${RAW_CLOUD_CONFIG_PATH}"
echo "hostname: '${HOSTNAME}'" >> "${RAW_CLOUD_CONFIG_PATH}"

exec $TASKSET /usr/bin/qemu-system-x86_64 \
  -name ${HOSTNAME} \
  -nographic \
  -machine accel=kvm -cpu host -smp ${CORES} \
  -m ${MEMORY} \
  -enable-kvm \
  -net \
  bridge,br=${NETWORK_BRIDGE_NAME},vlan=0,helper=/usr/libexec/qemu-bridge-helper \
  -net nic,vlan=0,model=virtio,macaddr=$MAC_ADDRESS \
  -fsdev \
  local,id=conf,security_model=none,readonly,path=/usr/code/cloudconfig \
  -device virtio-9p-pci,fsdev=conf,mount_tag=config-2 \
  $ETCD_DATA_VOLUME_PATH \
  -drive \
  if=virtio,file=$USRFS,format=raw,serial=usr.readonly \
  -drive \
  if=virtio,file=$ROOTFS,format=raw,discard=on,serial=rootfs \
  -device \
  sga \
  -serial mon:stdio \
  -kernel \
  $KERNEL \
  -append "console=ttyS0 root=/dev/disk/by-id/virtio-rootfs rootflags=rw mount.usr=/dev/disk/by-id/virtio-usr.readonly mount.usrflags=ro"
