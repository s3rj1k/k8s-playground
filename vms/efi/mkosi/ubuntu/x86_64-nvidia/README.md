**NVIDIA OS Image.**

*Install mkosi:*

    pipx install git+https://github.com/systemd/mkosi.git
    export PATH="$HOME/.local/bin:$PATH"
    mkosi --version

*Build RAW image:*

    mkosi build

*Build (force) RAW image:*

    mkosi -f build

*Build (force, autologin) RAW image:*

    mkosi --force build --autologin=true

*Convert RAW image to QCOW2:*

    qemu-img convert -f raw -O qcow2 -c image.vm.raw image.vm.qcow2

*Run RAW image using qemu:*

    mkosi qemu

*Set console size:*

    stty rows 40 cols 160

*Cloud-init (KubeVirt) Configuration Example:*

```yaml
- cloudInitNoCloud:
    userData: |-
      #cloud-config
      password: password
      chpasswd: { expire: False }
      disable_root: true
      write_files:
        - content: |
            [Resolve]
            DNS=1.1.1.1 8.8.8.8
          path: "/etc/systemd/resolved.conf.d/dns.conf"
      runcmd:
        - systemctl restart systemd-resolved
        - apt update
        - apt upgrade -y
        - DEBIAN_FRONTEND=noninteractive apt install -y nvidia-driver-570-open libnvidia-nscq-570 nvidia-modprobe nvidia-fabricmanager-570 datacenter-gpu-manager-4-cuda12 nv-persistence-mode nvlsm libnvsdm-570
        - systemctl enable --now nvidia-fabricmanager nvidia-persistenced nvidia-dcgm
        - DEBIAN_FRONTEND=noninteractive apt install -y nvidia-system-mlnx-drivers
```

*Installing NVIDIA Drivers into Image and Creating KubeVirt ContainerDisk:*

1. Build the base image:
```bash
mkosi -f build
```

2. Create and expand QCOW2 image:
```bash
# Check partitions (optional)
# virt-filesystems --long --parts --blkdevs -a image.vm.raw
qemu-img create -f qcow2 -o preallocation=metadata image.vm.qcow2 100G
virt-resize --expand /dev/sda3 image.vm.raw image.vm.qcow2
```

3. Boot the VM and install NVIDIA drivers:
```bash
qemu-system-x86_64 \
  -m 16384 \
  -smp 32 \
  -enable-kvm \
  -netdev user,id=net0 \
  -device virtio-net,netdev=net0 \
  -drive file=image.vm.qcow2,format=qcow2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS_4M.fd \
  -nographic
```

4. Inside the VM, install NVIDIA drivers:
```bash
apt update && apt upgrade -y

DEBIAN_FRONTEND=noninteractive apt install -y nvidia-driver-570-open libnvidia-nscq-570 nvidia-modprobe nvidia-fabricmanager-570 datacenter-gpu-manager-4-cuda12 nv-persistence-mode nvlsm libnvsdm-570

systemctl enable nvidia-fabricmanager nvidia-persistenced nvidia-dcgm

DEBIAN_FRONTEND=noninteractive apt install -y nvidia-system-mlnx-drivers

apt -y -f install apt-utils
apt clean
```

5. Shutdown VM and sparsify the image:
```bash
virt-sparsify image.vm.qcow2 os.qcow2
```

6. Create KubeVirt ContainerDisk image:
```bash
cat << 'EOF' > Dockerfile
FROM scratch
ADD --chown=107:107 os.qcow2 /disk/
EOF

docker build -t ghcr.io/s3rj1k/ubuntu-noble-nvidia:1755355645 .

### docker login ghcr.io -u s3rj1k
### https://github.com/settings/tokens
```

*NVIDIA related links*:

    https://docs.nvidia.com/dgx/dgx-os-7-user-guide/installing_on_ubuntu.html#installing-on-ubuntu
    https://docs.nvidia.com/dgx/dgx-os-7-user-guide/installing_on_ubuntu.html#installing-the-gpu-driver
    https://docs.nvidia.com/dgx/dgx-os-7-user-guide/installing_on_ubuntu.html#installing-the-doca-ofed-package
    https://github.com/kubevirt/kubevirt/blob/main/docs/container-register-disks.md#high-level-design

    Test with: `nvidia-smi`, `nvidia-smi topo -m`
