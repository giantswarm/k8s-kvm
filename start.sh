#!/bin/bash

# The following parameters have to be given.
#
#     ${CORES}                  e.g. "1"
#     ${DISK_DOCKER}            e.g. "4G"
#     ${DISK_KUBELET}           e.g. "4G"
#     ${DISK_OS}                e.g. "4G"
#     ${HOSTNAME}               e.g. "kvm-master-1"
#     ${NETWORK_BRIDGE_NAME}    e.g. "br-h8s2l"
#     ${NETWORK_TAP_NAME}       e.g. "tap-h8s2l"
#     ${MEMORY}                 e.g. "2048"
#     ${ROLE}                   e.g. "master" or "worker"
#     ${CLOUD_CONFIG_PATH}      e.g. "/cloudconfig/user_data"
#     ${COREOS_VERSION}         e.g. "1409.7.0"

set -eu

raw_ignition_dir="/usr/code/ignition"

if [ -z ${CLOUD_CONFIG_PATH} ]; then
    echo "CLOUD_CONFIG_PATH must be set." >&2
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
  echo "Waiting for ip address on interface ${NETWORK_BRIDGE_IP}."
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
mkdir -p ${raw_ignition_dir}

ROOTFS="/usr/code/rootfs/rootfs.img"
DOCKERFS="/usr/code/rootfs/dockerfs.img"
KUBELETFS="/usr/code/rootfs/kubeletfs.img"
MAC_ADDRESS=$(printf 'DE:AD:BE:%02X:%02X:%02X\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))


#
# Prepare CoreOS images.
#

IMGDIR="/usr/code/images"
KERNEL="${IMGDIR}/coreos_production_pxe.vmlinuz"
INITRD="${IMGDIR}/coreos_production_pxe_image.cpio.gz"

mkdir -p ${IMGDIR}

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


/qemu-node-setup -bridge-ip=${NETWORK_BRIDGE_IP} -hostname=${HOSTNAME} -main-config="${raw_ignition_dir}/${ROLE}.json" -out="${raw_ignition_dir}/final.json"


#added PMU off to `-cpu host,pmu=off` https://github.com/giantswarm/k8s-kvm/pull/14
exec $TASKSET /usr/bin/qemu-system-x86_64 \
  -name ${HOSTNAME} \
  -nographic \
  -machine accel=kvm \
  -cpu host,pmu=off \
  -smp ${CORES} \
  -m ${MEMORY} \
  -enable-kvm \
  -device virtio-net-pci,netdev=${NETWORK_TAP_NAME},mac=${MAC_ADDRESS} \
  -netdev tap,id=${NETWORK_TAP_NAME},ifname=${NETWORK_TAP_NAME},downscript=no \
  -fw_cfg name=opt/com.coreos/config,file=${raw_ignition_dir}/final.json \
  $ETCD_DATA_VOLUME_PATH \
  -drive if=virtio,file=${ROOTFS},format=raw,discard=on,serial=rootfs \
  -drive if=virtio,file=${DOCKERFS},format=raw,discard=on,serial=dockerfs \
  -drive if=virtio,file=${KUBELETFS},format=raw,discard=on,serial=kubeletfs \
  -device sga \
  -device virtio-rng-pci \
  -serial stdio \
  -monitor unix:/qemu-monitor,server,nowait \
  -kernel $KERNEL \
  -initrd $INITRD \
  -append "console=ttyS0 root=/dev/disk/by-id/virtio-rootfs rootflags=rw coreos.first_boot=1"
