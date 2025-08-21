# Running Ubuntu Cloud VM with Cloud-Init in libvirt

This guide shows how to create and run an Ubuntu cloud VM locally using libvirt with cloud-init configuration.

## Steps

### Download Ubuntu Cloud Image

```bash
sudo mkdir -p /var/lib/libvirt/images
sudo wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img \
  -O /var/lib/libvirt/images/ubuntu-22.04-server-cloudimg-amd64.img
```

### Create Cloud-Init Configuration

Create user-data file:
```bash
cat > /tmp/user-data << 'EOF'
#cloud-config
users:
 - name: ubuntu
   sudo: ALL=(ALL) NOPASSWD:ALL
   shell: /bin/bash
   lock_passwd: false
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: False
ssh_pwauth: True
EOF
```

Create meta-data file:
```bash
cat > /tmp/meta-data << 'EOF'
instance-id: vm
local-hostname: vm
EOF
```

### Create Cloud-Init ISO

```bash
genisoimage -output /tmp/cloud-init-vm.iso -volid cidata -joliet -rock /tmp/user-data /tmp/meta-data
```

### Prepare VM Disk

```bash
# Copy cloud image to VM disk
sudo cp /var/lib/libvirt/images/ubuntu-22.04-server-cloudimg-amd64.img /var/lib/libvirt/images/vm-disk.qcow2

# Resize disk to 20GB
sudo qemu-img resize /var/lib/libvirt/images/vm-disk.qcow2 20G
```

### Create and Start VM

Replace `<bridge_name>` with your bridge network name:
- `virbr0` - Default libvirt bridge
- `br0` - Common custom bridge name
- Use `virsh net-list` to see available networks

```bash
sudo virt-install \
  --name vm \
  --description "Ubuntu Cloud VM" \
  --vcpus 4 \
  --ram 8192 \
  --os-variant ubuntu22.04 \
  --disk path=/var/lib/libvirt/images/vm-disk.qcow2,bus=virtio \
  --disk path=/tmp/cloud-init-vm.iso,device=cdrom \
  --network bridge=<bridge_name>,mac=52:54:00:12:34:01 \
  --graphics vnc \
  --boot hd \
  --noautoconsole \
  --import
```

### Connect to VM

Login credentials: `ubuntu` / `ubuntu`

Connect via console:
```bash
virsh console vm
# Press Ctrl+] to disconnect
```

Or connect via VNC:
```bash
virt-viewer vm
```

### Cleanup (Optional)

To remove the VM and clean up:
```bash
# Stop and remove VM
virsh destroy vm
virsh undefine vm --remove-all-storage --nvram --snapshots-metadata --managed-save

# Remove temporary files
rm -f /tmp/user-data /tmp/meta-data /tmp/cloud-init-vm.iso
```
