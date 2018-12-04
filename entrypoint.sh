#!/bin/bash

set -eux

echo "Starting firecracker server"
chmod +x /firecracker
/firecracker \
    --api-sock /tmp/firecracker.sock \
    &

echo "Setting guest kernel"
# TODO: Check boot_args.
curl \
    --unix-socket /tmp/firecracker.sock \
    --include \
    --request PUT 'http://localhost/boot-source' \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data '{
        "kernel_image_path": "/vmlinuz",
        "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
    }'

echo "Setting guest rootfs"
# TODO: Decide on read only rootfs.
curl \
    --unix-socket /tmp/firecracker.sock \
    --include \
    --request PUT 'http://localhost/drives/rootfs' \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data '{
        "drive_id": "rootfs",
        "path_on_host": "/rootfs",
        "is_root_device": true,
        "is_read_only": false
    }'

echo "Setting guest config"
# TODO: Pull CPU and memory from args.
curl \
    --unix-socket /tmp/firecracker.sock \
    --include \
    --request PUT 'http://localhost/machine-config' \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data '{
        "vcpu_count": 2,
        "mem_size_mib": 2048
    }'

echo "Starting guest machine"
curl \
    --unix-socket /tmp/firecracker.sock \
    --include \
    --request PUT 'http://localhost/actions' \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data '{
        "action_type": "InstanceStart"
     }'
