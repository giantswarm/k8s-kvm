#!/bin/bash

# The following parameters have to be given.
#
#     ${CORES}                  e.g. "1"
#     ${DISK_DOCKER}            e.g. "4G"
#     ${DISK_KUBELET}           e.g. "4G"
#     ${DISK_OS}                e.g. "4G"
#     ${DNS_SERVERS}            e.g. "1.1.1.1,8.8.4.4"
#     ${HOSTNAME}               e.g. "kvm-master-1"
#     ${MEMORY}                 e.g. "2048"
#     ${NETWORK_BRIDGE_NAME}    e.g. "br-h8s2l"
#     ${NETWORK_TAP_NAME}       e.g. "tap-h8s2l"
#     ${NTP_SERVERS}            e.g. "0.coreos.pool.ntp.org,1.coreos.pool.ntp.org"
#     ${ROLE}                   e.g. "master" or "worker"
#     ${CLOUD_CONFIG_PATH}      e.g. "/cloudconfig/user_data"
#     ${FLATCAR_VERSION}        e.g. "1409.7.0"
#     ${FLATCAR_CHANNEL}        e.g. "alpha"
#     ${DEBUG}                  e.g. "true"

set -eu

if [ "${DEBUG:-}" == "true" ]; then
  set -vx
fi

if [ -z "${CLOUD_CONFIG_PATH}" ]; then
  echo "CLOUD_CONFIG_PATH must be set." >&2
  exit 1
fi

if [ -z "${FLATCAR_VERSION}" ]; then
  echo "FLATCAR_VERSION must be set." >&2
  exit 1
fi

#
# Find IP of network bridge.
#

NETWORK_BRIDGE_IP=""

while :; do
  NETWORK_BRIDGE_IP=$(/sbin/ifconfig "$NETWORK_BRIDGE_NAME" | grep 'inet ' | awk '{print $2}' | cut -d ':' -f 2)
  if [ -n "$NETWORK_BRIDGE_IP" ]; then
    break
  fi
  echo "Waiting for ip address on interface ${NETWORK_BRIDGE_NAME}."
  sleep 1
done

echo "Found network bridge IP '${NETWORK_BRIDGE_IP}' for network bridge name '${NETWORK_BRIDGE_NAME}'."

#
# Enable the VM's network bridge.
#

mkdir -p /etc/qemu
echo "allow ${NETWORK_BRIDGE_NAME}" >/etc/qemu/bridge.conf

#
# Prepare FS.
#

RAW_IGNITION_DIR="/usr/code/ignition"

mkdir -p /usr/code/rootfs/
mkdir -p $RAW_IGNITION_DIR

#
# Prepare Flatcar images.
#

IMGDIR="/usr/code/images/v2"
KERNEL="flatcar_production_pxe.vmlinuz"
INITRD="flatcar_production_pxe_image.cpio.gz"
FLATCAR_CHANNEL=${FLATCAR_CHANNEL:-stable}

mkdir -p ${IMGDIR}

# Check if images already in place, if not download them.
# Download if does not exist.
if [ ! -f "${IMGDIR}/${FLATCAR_VERSION}/done.lock" ]; then
  # Prepare directory for images.
  rm -rf "${IMGDIR:?}"/"${FLATCAR_VERSION}"
  mkdir -p "${IMGDIR}"/"${FLATCAR_VERSION}"
  cd ${IMGDIR}/"${FLATCAR_VERSION}"

  # Download images.
  curl --fail -O https://"$FLATCAR_CHANNEL".release.flatcar-linux.net/amd64-usr/"$FLATCAR_VERSION"/$KERNEL
  curl --fail -O https://"$FLATCAR_CHANNEL".release.flatcar-linux.net/amd64-usr/"$FLATCAR_VERSION"/$INITRD

  # Check the signatures after download.
  # XXX: Assume local storage is trusted, do not check everytime pod starts.
  curl --fail -sL https://kinvolk.io/flatcar-container-linux/security/image-signing-key/Flatcar_Image_Signing_Key.asc | gpg --import -
  curl --fail -O https://"$FLATCAR_CHANNEL".release.flatcar-linux.net/amd64-usr/"$FLATCAR_VERSION"/$KERNEL.sig
  curl --fail -O https://"$FLATCAR_CHANNEL".release.flatcar-linux.net/amd64-usr/"$FLATCAR_VERSION"/$INITRD.sig
  gpg --verify ${KERNEL}.sig
  gpg --verify ${INITRD}.sig

  # Do cleanup.
  rm -f $KERNEL.sig
  rm -f $INITRD.sig

  # Create lock.
  touch done.lock
  cd -
fi

KERNEL="${IMGDIR}/${FLATCAR_VERSION}/${KERNEL}"
INITRD="${IMGDIR}/${FLATCAR_VERSION}/${INITRD}"

#
# Prepare root FS.
#

ROOTFS="/usr/code/rootfs/rootfs.img"
DOCKERFS="/usr/code/rootfs/dockerfs.img"
KUBELETFS="/usr/code/rootfs/kubeletfs.img"
MAC_ADDRESS=$(printf 'DE:AD:BE:%02X:%02X:%02X\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))

rm -f $ROOTFS $DOCKERFS $KUBELETFS
truncate -s "$DISK_OS" $ROOTFS
mkfs.xfs $ROOTFS
truncate -s "$DISK_DOCKER" $DOCKERFS
mkfs.xfs $DOCKERFS
truncate -s "$DISK_KUBELET" $KUBELETFS
mkfs.xfs $KUBELETFS

#
# Ensure proper mounts.
#

ETCD_DATA_VOLUME_PATH=""

if [ "$ROLE" = "master" ]; then
  ETCD_DATA_VOLUME_PATH="-fsdev local,security_model=none,id=fsdev1,path=/etc/kubernetes/data/etcd/ -device virtio-9p-pci,id=fs1,fsdev=fsdev1,mount_tag=etcdshare"
fi

# Define the the mount tag and the  mount point in the host machine
# These values will be defined in the kvm-operator during the bootstrap of the cluster
#
# i.e. HOST_DATA_VOLUME_PATHS=datashare1:/data1,datashare2:/data2
#
HOST_DATA_VOLUME_CONFIG=""
IFS=','

if [ "$ROLE" = "worker" ]; then
  if [ -n "$HOST_DATA_VOLUME_PATHS" ]; then
    read -a mountpoints <<< "$HOST_DATA_VOLUME_PATHS"

    for idx in "${!mountpoints[@]}"; do
      mount_tag=$(echo "${mountpoints[$idx]}" | cut -d ':' -f 1)
      mount_path=$(echo "${mountpoints[$idx]}" | cut -d ':' -f 2)

      HOST_DATA_VOLUME_CONFIG+="-fsdev local,security_model=none,id=fsdev$((idx+1)),path=${mount_path} -device virtio-9p-pci,id=$((idx+1)),fsdev=fsdev$((idx+1)),mount_tag=$mount_tag "
    done
  fi
fi

# Pin the vm on a certain CPU. Make sure the variable is set and a CPU value is
# given.

TASKSET=
PIN_CPU=${PIN_CPU:-}

if [ -n "$PIN_CPU" ]; then
  TASKSET="taskset -ac ${PIN_CPU}"
fi

#
# Boot the VM.
#

# Extract ignition from mounted configmap into raw provision config.
base64 <"${CLOUD_CONFIG_PATH}" -d | gunzip >"$RAW_IGNITION_DIR/${ROLE}.json"

# Generate final ignition with static network configuration and hostname
# Configuration tool: https://github.com/giantswarm/qemu-node-setup
# Usage of ./qemu-node-setup:
#  -bridge-ip string
#        IP address of the bridge (used to retrieve interface ip).
#  -dns-servers string
#        Colon separated list of DNS servers.
#  -hostname string
#        Hostname of the tenant node.
#  -main-config string
#        Path to main ignition config (appended to small).
#  -ntp-servers string
#        Colon separated list of NTP servers.
#  -out string
#        Path to save resulting ignition config.
/qemu-node-setup -bridge-ip="$NETWORK_BRIDGE_IP" -dns-servers="$DNS_SERVERS" -hostname="$HOSTNAME" -main-config="${RAW_IGNITION_DIR}/${ROLE}.json" \
  -ntp-servers="${NTP_SERVERS}" -out="$RAW_IGNITION_DIR/final.json"

#added PMU off to `-cpu host,pmu=off` https://github.com/giantswarm/k8s-kvm/pull/14
eval exec "$TASKSET" /usr/local/bin/qemu-system-x86_64 \
  -name "$HOSTNAME" \
  -nographic \
  -machine type=q35,accel=kvm \
  -cpu host,pmu=off \
  -smp "$CORES" \
  -m "$MEMORY" \
  -enable-kvm \
  -device virtio-net-pci,netdev="$NETWORK_TAP_NAME",mac="$MAC_ADDRESS" \
  -netdev tap,id="$NETWORK_TAP_NAME",ifname="$NETWORK_TAP_NAME",script=/etc/qemu-ifup,downscript=no \
  -fw_cfg name=opt/org.flatcar-linux/config,file="$RAW_IGNITION_DIR"/final.json \
  -drive if=none,file="$ROOTFS",format=raw,discard=on,id=rootfs \
  -device virtio-blk-pci,drive=rootfs,serial=rootfs \
  -drive if=none,file="$DOCKERFS",format=raw,discard=on,id=dockerfs \
  -device virtio-blk-pci,drive=dockerfs,serial=dockerfs \
  -drive if=none,file="$KUBELETFS",format=raw,discard=on,id=kubeletfs \
  -device virtio-blk-pci,drive=kubeletfs,serial=kubeletfs \
  "$ETCD_DATA_VOLUME_PATH" \
  "$HOST_DATA_VOLUME_CONFIG" \
  -device sga \
  -device virtio-rng-pci \
  -serial stdio \
  -monitor unix:/qemu-monitor,server,nowait \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "\"console=ttyS0 root=/dev/disk/by-id/virtio-rootfs rootflags=rw flatcar.first_boot=1\""
