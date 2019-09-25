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
#     ${NTP_SERVERS}            e.g. "0.coreos.pool.ntp.org,1.coreos.pool.ntp.org"
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
# Prepare FS.
#

mkdir -p /usr/code/rootfs/
mkdir -p ${raw_ignition_dir}

ROOTFS="/usr/code/rootfs/rootfs.img"
DOCKERFS="/usr/code/rootfs/dockerfs.img"
KUBELETFS="/usr/code/rootfs/kubeletfs.img"
MAC_ADDRESS=$(printf 'DE:AD:BE:%02X:%02X:%02X\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
IP_ADDRESS=$(ip -j addr show eth0 | jq -r .[0].addr_info[0].local)

#
# Prepare CoreOS images.
#

IMGDIR="/usr/code/images/v2"
KERNEL="${IMGDIR}/coreos_production_pxe.vmlinuz"
INITRD="${IMGDIR}/coreos_production_pxe_image.cpio.gz"

mkdir -p ${IMGDIR}

# Use specific CoreOS version, if ${COREOS_VERSION} is set and not empty.
# Check if images already in place, if not download them.
if [ ! -z ${COREOS_VERSION+x} ] && [ ! -z "${COREOS_VERSION}" ]; then
  KERNEL="${IMGDIR}/${COREOS_VERSION}/coreos_production_pxe.vmlinuz"
  INITRD="${IMGDIR}/${COREOS_VERSION}/coreos_production_pxe_image.cpio.gz"

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

    # Do cleanup.
    rm -f coreos_production_pxe.vmlinuz.sig
    rm -f coreos_production_pxe_image.cpio.gz.sig

    # Create lock.
    touch done.lock; cd -
  fi
else
	echo "ERROR: COREOS_VERSION env not set."
	exit 1
fi


#
# Prepare root FS.
#

rm -f ${ROOTFS} ${DOCKERFS} ${KUBELETFS}
truncate -s ${DISK_OS} ${ROOTFS}
mkfs.xfs ${ROOTFS}
truncate -s ${DISK_DOCKER} ${DOCKERFS}
mkfs.xfs ${DOCKERFS}
truncate -s ${DISK_KUBELET} ${KUBELETFS}
mkfs.xfs ${KUBELETFS}

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

# Extract ignition from mounted configmap into raw provision config.
cat "${CLOUD_CONFIG_PATH}" | base64 -d | gunzip > "${raw_ignition_dir}/${ROLE}.json"

# this is bad-hack for kubelet beging too carefull
# when kubelet starts a pod it checks if the IP from CNI is somehow working and since we remove the IP from eth0 and set it on VM it will be unresponsive until the VM is fully booted, this causes issues on instalaltions with slow booting time as geckon/gorgoth
# without this hack kubelet will be killing the pod undefinetly with 'PodSandboxChanged' event
sleep 10s

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
/qemu-node-setup -node-ip=${IP_ADDRESS} -dns-servers=${DNS_SERVERS} -hostname=${HOSTNAME} -main-config="${raw_ignition_dir}/${ROLE}.json" \
                 -ntp-servers=${NTP_SERVERS} -out="${raw_ignition_dir}/final.json"

# rewrite eth packet destination MAC address from container eth0 to the VM eth0 via tc
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: protocol all u32 match u32 0 0 action pedit ex munge eth dst set ${MAC_ADDRESS}

#added PMU off to `-cpu host,pmu=off` https://github.com/giantswarm/k8s-kvm/pull/14
exec $TASKSET /usr/bin/qemu-system-x86_64 \
  -name ${HOSTNAME} \
  -nographic \
  -machine type=q35,accel=kvm \
  -cpu host,pmu=off \
  -smp ${CORES} \
  -m ${MEMORY} \
  -enable-kvm \
  -nic tap,model=virtio-net-pci,downscript=no,mac=${MAC_ADDRESS} \
  -fw_cfg name=opt/com.coreos/config,file=${raw_ignition_dir}/final.json \
  -drive if=none,file=${ROOTFS},format=raw,discard=on,id=rootfs \
  -device virtio-blk-pci,drive=rootfs,serial=rootfs \
  -drive if=none,file=${DOCKERFS},format=raw,discard=on,id=dockerfs \
  -device virtio-blk-pci,drive=dockerfs,serial=dockerfs \
  -drive if=none,file=${KUBELETFS},format=raw,discard=on,id=kubeletfs \
  -device virtio-blk-pci,drive=kubeletfs,serial=kubeletfs \
  $ETCD_DATA_VOLUME_PATH \
  -device sga \
  -device virtio-rng-pci \
  -serial stdio \
  -monitor unix:/qemu-monitor,server,nowait \
  -kernel $KERNEL \
  -initrd $INITRD \
  -append "console=ttyS0 root=/dev/disk/by-id/virtio-rootfs rootflags=rw coreos.first_boot=1"
