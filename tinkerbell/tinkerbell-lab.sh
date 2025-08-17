#!/bin/bash

# Copyright 2025 s3rj1k
# SPDX-License-Identifier: MIT

# Tinkerbell Lab Setup Script
#
# Lint: shfmt -w -s -ci -sr -kp -fn tinkerbell-lab.sh
# Commit to gist: git commit --allow-empty-message -S -am ''
#
# Example: Override Helm chart repo, version and HookOS
#   export TINKERBELL_CHART_REPO="oci://ghcr.io/bellfork/charts/tinkerbell"
#   export TINKERBELL_CHART_VERSION="v0.0.0-b4103e2"
#   export HOOKOS_DOWNLOAD_URL=https://github.com/bellfork/CI/releases/download/v0.11.1-abe190b
#   ./tinkerbell-lab.sh
#
# Refs:
#   - https://github.com/tinkerbell/tinkerbell/blob/main/helm/tinkerbell/README.md
#   - https://github.com/tinkerbell/tinkerbell/blob/main/docs/technical/rufio/README.md#job-api
#   - https://github.com/tinkerbell/tinkerbell/blob/main/docs/technical/BOOT_MODES.md#customboot
#   - https://github.com/tinkerbell/playground/
#   - https://github.com/s3rj1k/libvirt-ipmi (for IPMI and Sushy emulator daemons)
#

set -euo pipefail

# Parse command line arguments
parse_args()
{
	CLEANUP_ONLY=false
	ENABLE_VM=""

	while [[ $# -gt 0 ]]; do
		case $1 in
			--cleanup-only)
				CLEANUP_ONLY=true
				shift
				;;
			--enable-and-attach)
				ENABLE_VM="$2"
				shift 2
				;;
			-h | --help)
				echo "Usage: $0 [OPTIONS]"
				echo "Options:"
				echo "  --cleanup-only                 Only perform cleanup and exit"
				echo "  --enable-and-attach <vm_name>  Enable workflow for VM and attach to console"
				echo "  -h, --help                     Show this help message"
				exit 0
				;;
			*)
				echo "Unknown option: $1"
				echo "Use --help for usage information"
				exit 1
				;;
		esac
	done
}

# Set configuration from environment variables
set_config()
{
	# KinD Configuration
	KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
	IMAGE_REGISTRY="${IMAGE_REGISTRY:-dockerproxy.artifactory-eu.mcp.mirantis.net}"

	# CNI Configuration (calico, kube-router)
	CNI_PROVIDER="${CNI_PROVIDER:-calico}"

	# Tinkerbell Configuration
	TINKERBELL_CHART_REPO="${TINKERBELL_CHART_REPO:-oci://ghcr.io/tinkerbell/charts/tinkerbell}"
	TINKERBELL_CHART_VERSION="${TINKERBELL_CHART_VERSION:-}"
	NAMESPACE="tinkerbell"

	# HookOS Configuration
	HOOKOS_DOWNLOAD_URL="${HOOKOS_DOWNLOAD_URL:-https://github.com/tinkerbell/hook/releases/download/v0.11.1}"
	# See: https://github.com/tinkerbell/tinkerbell/issues/300
	HOOKOS_ISO_URL="${HOOKOS_DOWNLOAD_URL}/hook-latest-lts-x86_64-efi-initrd.iso"

	# Template names
	TEMPLATE_NAME_KEXEC="ubuntu-kexec"
	TEMPLATE_NAME_NOKEXEC="ubuntu-nokexec"

	# VM Configuration
	VM1_NAME="vm1"
	VM1_MAC="52:54:00:12:34:01"
	VM2_NAME="vm2"
	VM2_MAC="52:54:00:12:34:02"
	VM3_NAME="vm3"
	VM3_MAC="52:54:00:12:34:03"

	# BMC Configuration
	BMC_PORT="623"
	BMC_PASS_BASE64=$(cat ~/.ipmi_password | base64)

	# Redfish Configuration
	REDFISH_PORT="8000"
	REDFISH_PASS_BASE64=$(cat ~/.redfish_password | base64)
}

# Check if required binaries are available
check_prerequisites()
{
	local required_binaries=(
		"awk"
		"base64"
		"basename"
		"cat"
		"curl"
		"cut"
		"docker"
		"ethtool"
		"grep"
		"helm"
		"jq"
		"kind"
		"kubectl"
		"sed"
		"systemctl"
		"tr"
		"virsh"
		"virt-install"
		"xargs"
	)

	local required_services=(
		"docker"
		"libvirtd"
		"libvirt-ipmi"
		"sushy-emulator"
	)

	echo -e "\nChecking prerequisites ..."

	for binary in "${required_binaries[@]}"; do
		if command -v "$binary" &> /dev/null; then
			echo "  ✓ $binary found"
		else
			echo "  ✗ $binary missing"
			echo "Error: Required binary '$binary' is not available."
			exit 1
		fi
	done

	for service in "${required_services[@]}"; do
		if systemctl is-active --quiet "$service"; then
			echo "  ✓ $service daemon running"
		else
			echo "  ✗ $service daemon not running"
			echo "Error: Required service '$service' is not running."
			exit 1
		fi
	done

	echo -e "\nAll prerequisites are available."
}

# Create default storage pool for libvirt
create_storage_pool()
{
	echo -e "\nSetting up libvirt storage pool ..."

	local pool_name="default"
	local pool_path="/var/lib/libvirt/default-image-pool"

	if virsh pool-list --all | grep -q "$pool_name"; then
		if ! virsh pool-list | grep -q "$pool_name.*active"; then
			echo "Starting default storage pool ..."
			virsh pool-start "$pool_name"
		fi

		virsh pool-autostart "$pool_name"
	else
		echo "Creating default storage pool at $pool_path ..."

		mkdir -p "$pool_path"
		virsh pool-define-as "$pool_name" dir --target "$pool_path"
		virsh pool-build "$pool_name"
		virsh pool-start "$pool_name"
		virsh pool-autostart "$pool_name"
	fi

	echo "Storage pool status:"
	virsh pool-list --all
	echo "Storage pool setup completed successfully"
}

# Clean up all existing resources
cleanup_all()
{
	echo -e "\nStarting comprehensive cleanup ..."

	echo -e "\nDeleting all kind clusters ..."
	kind delete clusters --all || true

	echo -e "\nStopping all running containers ..."
	if docker ps -q | grep -q .; then
		docker ps -q | xargs -r docker stop -t 0
	else
		echo "No running containers found"
	fi

	echo -e "\nCleaning up Docker system ..."
	docker system prune -af

	echo -e "\nCleaning up VMs ..."
	for vm in $(virsh list --all --name | grep -E "^(vm|node)"); do
		echo "Force destroying VM: $vm"
		virsh destroy "$vm" || true

		echo "Undefining VM: $vm with complete cleanup"
		virsh undefine "$vm" --remove-all-storage --nvram --snapshots-metadata --managed-save || true
	done

	echo -e "\nCleanup completed successfully!"
}

# Setup KinD configuration files
setup_kind_config()
{
	echo -e "\nCreating KinD config with registry: ${IMAGE_REGISTRY}"
	mkdir -p $HOME/.kind/

	cat << EOF > $HOME/.kind/default_hosts.toml
[host."https://${IMAGE_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  # skip_verify = true
EOF

	cat << 'EOF' > $HOME/.kind/config
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $HOME/.kind/default_hosts.toml
        containerPath: /etc/containerd/certs.d/_default/hosts.toml
        readOnly: true
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
        readOnly: false
containerdConfigPatches:
  - |-
    [plugins.'io.containerd.cri.v1.images'.registry]
       config_path = '/etc/containerd/certs.d'
EOF

	sed -i "s|\$HOME|$HOME|g" ~/.kind/config
	echo "KinD configuration created successfully"
}

# Fetch the latest Calico version
get_calico_version()
{
	echo -e "\nFetching latest Calico version ..."
	CALICO_VERSION=$(curl -s "https://api.github.com/repos/projectcalico/calico/releases/latest" | jq -r ".tag_name")

	if [ -z "$CALICO_VERSION" ] || [ "$CALICO_VERSION" = "null" ]; then
		echo "Error: Failed to fetch Calico version"
		exit 1
	fi

	echo "Using Calico version: ${CALICO_VERSION}"
}

# Fetch the latest kube-router version
get_kube_router_version()
{
	echo -e "\nFetching latest kube-router version ..."
	KUBE_ROUTER_VERSION=$(curl -s "https://api.github.com/repos/cloudnativelabs/kube-router/releases/latest" | jq -r ".tag_name")

	if [ -z "$KUBE_ROUTER_VERSION" ] || [ "$KUBE_ROUTER_VERSION" = "null" ]; then
		echo "Error: Failed to fetch kube-router version"
		exit 1
	fi

	echo "Using kube-router version: ${KUBE_ROUTER_VERSION}"
}

# Create the Kind cluster
create_kind_cluster()
{
	echo -e "\nCreating Kind cluster: ${KIND_CLUSTER_NAME}"

	if ! kind create cluster --verbosity 1 --name "${KIND_CLUSTER_NAME}" --retain --config ~/.kind/config; then
		echo "Error: Failed to create Kind cluster"
		exit 1
	fi

	echo "Kind cluster '${KIND_CLUSTER_NAME}' created successfully"
}

# Set network IPs from Kind cluster gateway
set_network_ips()
{
	echo -e "\nSetting network IPs from Kind cluster gateway ..."

	KIND_NETWORK_INFO=$(docker network inspect kind)
	KIND_SUBNET=$(echo "$KIND_NETWORK_INFO" | jq -r '.[0].IPAM.Config[] | select(.Subnet | contains(".")) | .Subnet')
	KIND_GATEWAY=$(echo "$KIND_NETWORK_INFO" | jq -r '.[0].IPAM.Config[] | select(.Gateway) | .Gateway')

	if [ -z "$KIND_SUBNET" ] || [ -z "$KIND_GATEWAY" ]; then
		echo "Error: Failed to get Kind network configuration"
		exit 1
	fi

	echo -e "\nKind network subnet: $KIND_SUBNET"
	echo "Kind network gateway: $KIND_GATEWAY"

	NETWORK_BASE=$(echo "$KIND_GATEWAY" | awk -F"." '{print $1"."$2"."$3}')

	BMC_IP="$KIND_GATEWAY"
	REDFISH_IP="$KIND_GATEWAY"
	GATEWAY_IP="$KIND_GATEWAY"
	NODE_IP_BASE="${NETWORK_BASE}.200"

	echo -e "\nBMC IP: $BMC_IP"
	echo "Gateway IP: $GATEWAY_IP"
	echo "Node IP Base: $NODE_IP_BASE"
}

# Configure bridge interface with ethtool tweaks
configure_bridge_interface()
{
	echo -e "\nConfiguring bridge interface with ethtool tweaks ..."
	echo "Using bridge interface: $BRIDGE_NAME"

	# Apply ethtool configuration
	# https://github.com/ipxe/ipxe/pull/863
	# Needed after iPXE increased the default TCP window size to 2MB.

	if ethtool -K "$BRIDGE_NAME" tx off sg off tso off; then
		echo "Successfully applied ethtool configuration to $BRIDGE_NAME"
	else
		echo "Warning: Failed to apply ethtool configuration to $BRIDGE_NAME"
		echo "This may cause issues with iPXE booting"
	fi
}

# Install Calico CNI
install_calico()
{
	echo -e "\nInstalling Calico ${CALICO_VERSION} ..."
	until kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" &> /dev/null; do
		echo "Waiting for cluster to be ready ..."
		sleep 5
	done

	echo "Calico ${CALICO_VERSION} installed successfully"
}

# Install kube-router CNI
install_kube_router()
{
	echo -e "\nInstalling kube-router ${KUBE_ROUTER_VERSION} ..."
	until kubectl create -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/${KUBE_ROUTER_VERSION}/daemonset/kubeadm-kuberouter.yaml" &> /dev/null; do
		echo "Waiting for cluster to be ready ..."
		sleep 5
	done

	echo "kube-router ${KUBE_ROUTER_VERSION} installed successfully"
}

# Wait for nodes to be ready
wait_for_nodes()
{
	echo -e "\nWaiting for nodes to be ready ..."
	until kubectl wait --for=condition=Ready nodes --all --timeout=300s &> /dev/null; do
		echo "Waiting for all nodes to be ready ..."
		sleep 10
	done

	echo "All nodes are ready"
}

# Set network configuration after Kind cluster creation
set_network_config()
{
	echo -e "\nSetting up network configuration ..."
	BRIDGE_NAME="br-$(docker network inspect -f '{{.Id}}' kind | cut -c1-12)"
	echo "Using bridge: ${BRIDGE_NAME}"
}

# Get Tinkerbell chart version
get_tinkerbell_version()
{
	if [ -n "$TINKERBELL_CHART_VERSION" ]; then
		echo -e "\nUsing pre-configured Tinkerbell chart version: ${TINKERBELL_CHART_VERSION}"
		return 0
	fi

	echo -e "\nFetching latest Tinkerbell chart version ..."
	TINKERBELL_CHART_VERSION=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/tinkerbell/tinkerbell/releases/latest))

	if [ -z "$TINKERBELL_CHART_VERSION" ]; then
		echo "Error: Failed to fetch Tinkerbell chart version"
		exit 1
	fi

	echo "Using Tinkerbell version: ${TINKERBELL_CHART_VERSION}"
}

# Setup Tinkerbell configuration
setup_tinkerbell_config()
{
	echo -e "\nSetting up Tinkerbell configuration ..."

	TINKERBELL_LB_IP="${NETWORK_BASE}.100"
	TINKERBELL_ARTIFACTS_SERVER="http://${NETWORK_BASE}.101:7173"
	TOOTLES_METADATA_URL="http://${TINKERBELL_LB_IP}:7172"

	echo -e "\nTinkerbell Chart Repository: $TINKERBELL_CHART_REPO"
	echo -e "\nTinkerbell LoadBalancer IP: $TINKERBELL_LB_IP"
	echo "Tinkerbell Artifacts Server: $TINKERBELL_ARTIFACTS_SERVER"
	echo "Tootles Metadata URL: $TOOTLES_METADATA_URL"
	echo -e "\nUsing HookOS download URL: $HOOKOS_DOWNLOAD_URL"

	echo -e "\nGetting pod CIDRs for trusted proxies ..."
	TRUSTED_PROXIES=$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' | tr ' ' ',')
	if [ -z "$TRUSTED_PROXIES" ]; then
		echo "Error: Failed to determine pod CIDRs"
		exit 1
	fi

	echo "KinD Trusted Proxies: ${TRUSTED_PROXIES}"
	echo "Tinkerbell configuration prepared"
}

# Install Tinkerbell
install_tinkerbell()
{
	echo -e "\nInstalling Tinkerbell ..."

	if ! helm install tinkerbell "$TINKERBELL_CHART_REPO" \
		--version "$TINKERBELL_CHART_VERSION" \
		--create-namespace \
		--namespace $NAMESPACE \
		--wait \
		--set "trustedProxies={${TRUSTED_PROXIES}}" \
		--set "publicIP=$TINKERBELL_LB_IP" \
		--set "artifactsFileServer=$TINKERBELL_ARTIFACTS_SERVER" \
		--set "optional.hookos.downloadURL=$HOOKOS_DOWNLOAD_URL" \
		--set "deployment.envs.smee.isoUpstreamURL=$HOOKOS_ISO_URL" \
		--set "deployment.envs.smee.ipxeHttpScriptExtraKernelArgs={console=tty0,console=ttyS0\,115200n8,linuxkit.runc_console=1,linuxkit.runc_debug=1}" \
		--set "deployment.envs.smee.osieURL=http://${TINKERBELL_LB_IP}:7171" \
		--set "deployment.envs.globals.logLevel=3"; then
		echo "Error: Failed to install Tinkerbell"
		exit 1
	fi

	echo "Tinkerbell ${TINKERBELL_CHART_VERSION} installed successfully from ${TINKERBELL_CHART_REPO}"
	echo "HookOS ISO upstream URL: $HOOKOS_ISO_URL"
}

# Create BMC machine secret (IPMI)
create_bmc_secret()
{
	local node_name=$1
	local bmc_user_base64=$(echo -n "$node_name" | base64)

	echo -e "\nCreating BMC secret: $node_name"

	cat << EOF | kubectl apply -f -
apiVersion: v1
data:
  password: $BMC_PASS_BASE64
  username: $bmc_user_base64
kind: Secret
metadata:
  name: $node_name
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
EOF

	echo "BMC secret created for $node_name"
}

# Create BMC machine secret (Redfish)
create_redfish_secret()
{
	local node_name=$1
	local redfish_user_base64=$(echo -n "admin" | base64)

	echo -e "\nCreating Redfish BMC secret: $node_name"

	cat << EOF | kubectl apply -f -
apiVersion: v1
data:
  password: $REDFISH_PASS_BASE64
  username: $redfish_user_base64
kind: Secret
metadata:
  name: ${node_name}-redfish
  namespace: $NAMESPACE
type: kubernetes.io/basic-auth
EOF

	echo "Redfish BMC secret created for $node_name"
}

# Create BMC machine for a VM (IPMI)
create_bmc_machine()
{
	local node_name=$1

	echo -e "\nCreating BMC machine: $node_name"

	cat << EOF | kubectl apply -f -
apiVersion: bmc.tinkerbell.org/v1alpha1
kind: Machine
metadata:
  name: $node_name
  namespace: $NAMESPACE
spec:
  connection:
    authSecretRef:
      name: $node_name
      namespace: $NAMESPACE
    host: $BMC_IP
    insecureTLS: true
    port: $BMC_PORT
    providerOptions:
      preferredOrder:
        - ipmitool
      ipmitool:
        cipherSuite: "3"
        port: $BMC_PORT
EOF

	echo "BMC machine created for $node_name"
}

# Create BMC machine for a VM (Redfish)
create_redfish_machine()
{
	local node_name=$1

	echo -e "\nCreating Redfish BMC machine: $node_name"

	cat << EOF | kubectl apply -f -
apiVersion: bmc.tinkerbell.org/v1alpha1
kind: Machine
metadata:
  name: $node_name
  namespace: $NAMESPACE
spec:
  connection:
    authSecretRef:
      name: ${node_name}-redfish
      namespace: $NAMESPACE
    host: $REDFISH_IP
    insecureTLS: true
    providerOptions:
      preferredOrder:
        - gofish
      redfish:
        port: $REDFISH_PORT
        useBasicAuth: true
        systemName: $node_name
EOF

	echo "Redfish BMC machine created for $node_name"
}

# Create hardware configuration for a node
create_hardware()
{
	local node_role=$1
	local node_name=$2
	local node_mac=$3
	local ip_offset=$4
	local uefi_enabled=$5

	echo -e "\nCreating hardware configuration for $node_name (role: $node_role, UEFI: $uefi_enabled)"

	local node_ip=$(awk -F"." '{print $1"."$2"."$3"."($4+'$ip_offset')}' <<< "$NODE_IP_BASE")

	cat << EOF | kubectl apply -f -
apiVersion: tinkerbell.org/v1alpha1
kind: Hardware
metadata:
  labels:
    tinkerbell.org/role: $node_role
  name: $node_name
  namespace: $NAMESPACE
spec:
  bmcRef:
    apiGroup: bmc.tinkerbell.org
    kind: Machine
    name: $node_name
  disks:
    - device: /dev/vda
  interfaces:
    - dhcp:
        arch: x86_64
        hostname: $node_name
        ip:
          address: $node_ip
          gateway: $GATEWAY_IP
          netmask: 255.255.255.0
        lease_time: 4294967294
        mac: $node_mac
        uefi: $uefi_enabled
        name_servers:
          - 8.8.8.8
          - 1.1.1.1
      netboot:
        allowPXE: true
        allowWorkflow: true
  userData: |
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
  metadata:
    instance:
      hostname: $node_name
      id: $node_mac
      operating_system:
        distro: "ubuntu"
        os_slug: "ubuntu_22_04"
        version: "22.04"
EOF

	echo "Hardware configuration created for $node_name (IP: $node_ip, UEFI: $uefi_enabled)"
}

# Create a VM
create_vm()
{
	local node_name=$1
	local mac_address=$2
	local uefi_enabled=$3

	local boot_options
	local graphics_options

	if [ "$uefi_enabled" = true ]; then
		boot_options="uefi,firmware.feature0.name=enrolled-keys,firmware.feature0.enabled=no,firmware.feature1.name=secure-boot,firmware.feature1.enabled=yes"
		graphics_options="vnc,listen=0.0.0.0"
		echo -e "\nCreating UEFI VM: $node_name with MAC: $mac_address"
	else
		boot_options="network,hd,bootmenu.enable=on,bios.useserial=on"
		graphics_options="vnc,listen=0.0.0.0"
		echo -e "\nCreating Legacy VM: $node_name with MAC: $mac_address"
	fi

	virt-install \
		--name "$node_name" \
		--description "VM" \
		--vcpus "2" \
		--ram "2048" \
		--os-variant "ubuntu22.04" \
		--connect "qemu:///system" \
		--disk "path=/var/lib/libvirt/images/${node_name}-disk.img,bus=virtio,size=10,sparse=yes" \
		--disk "device=cdrom,bus=sata" \
		--network "bridge:$BRIDGE_NAME,mac=$mac_address" \
		--console "pty,target.type=virtio" \
		--serial "pty" \
		--graphics "$graphics_options" \
		--import \
		--noautoconsole \
		--noreboot \
		--boot "$boot_options"

	echo "VM $node_name created"
}

# Create VMs and BMC resources for Tinkerbell
create_vms()
{
	echo -e "\nCreating VMs and BMC resources for Tinkerbell provisioning ..."

	# VM1 - Legacy BIOS with IPMI
	create_vm "$VM1_NAME" "$VM1_MAC" false
	create_bmc_secret "$VM1_NAME"
	create_bmc_machine "$VM1_NAME"
	create_hardware "control-plane" "$VM1_NAME" "$VM1_MAC" 1 false

	# VM2 - UEFI with IPMI
	create_vm "$VM2_NAME" "$VM2_MAC" true
	create_bmc_secret "$VM2_NAME"
	create_bmc_machine "$VM2_NAME"
	create_hardware "worker" "$VM2_NAME" "$VM2_MAC" 2 true

	# VM3 - UEFI with Redfish
	create_vm "$VM3_NAME" "$VM3_MAC" true
	create_redfish_secret "$VM3_NAME"
	create_redfish_machine "$VM3_NAME"
	create_hardware "worker" "$VM3_NAME" "$VM3_MAC" 3 true

	echo -e "\nVMs and BMC resources created successfully:"
	echo "VM1: $VM1_NAME ($VM1_MAC) - Legacy Boot with IPMI BMC"
	echo "VM2: $VM2_NAME ($VM2_MAC) - UEFI Boot with IPMI BMC"
	echo "VM3: $VM3_NAME ($VM3_MAC) - UEFI Boot with Redfish BMC"
	echo "Bridge: $BRIDGE_NAME"
	echo "BMC IP: $BMC_IP (Port: $BMC_PORT)"
	echo "Redfish IP: $REDFISH_IP (Port: $REDFISH_PORT)"
	echo "Gateway IP: $GATEWAY_IP"
	echo "Node IP Base: $NODE_IP_BASE"
}

# Create Ubuntu Template for Tinkerbell
create_template()
{
	local enable_kexec=$1
	local template_name=$2

	echo -e "\nCreating Template: $template_name for Tinkerbell (kexec: $enable_kexec) ..."

	# Build the actions array
	local actions_yaml=""

	# Stream Ubuntu Image action
	actions_yaml+='

          - name: "Stream Ubuntu Image"
            image: quay.io/tinkerbell/actions/image2disk:latest
            timeout: 600
            environment:
              DEST_DISK: {{ index .Hardware.Disks 0 }}
              IMG_URL: "'$TINKERBELL_ARTIFACTS_SERVER'/jammy-server-cloudimg-amd64.raw.gz"
              COMPRESSED: true'

	# Sync and Grow Partition action
	actions_yaml+='

          - name: "Sync and Grow Partition"
            image: quay.io/tinkerbell/actions/cexec:latest
            timeout: 90
            environment:
              BLOCK_DEVICE: {{ index .Hardware.Disks 0 }}1
              FS_TYPE: ext4
              CHROOT: y
              DEFAULT_INTERPRETER: "/bin/sh -c"
              CMD_LINE: "sync && growpart {{ index .Hardware.Disks 0 }} 1 && resize2fs {{ index .Hardware.Disks 0 }}1 && sync"'

	# Add Cloud-Init Config action
	actions_yaml+='

          - name: "Add Cloud-Init Config"
            image: quay.io/tinkerbell/actions/writefile:latest
            timeout: 90
            environment:
              CONTENTS: |
                datasource:
                  Ec2:
                    metadata_urls: ["'$TOOTLES_METADATA_URL'"]
                    strict_id: false
                manage_etc_hosts: localhost
                warnings:
                  dsid_missing_source: off
              DEST_DISK: {{ formatPartition ( index .Hardware.Disks 0 ) 1 }}
              DEST_PATH: /etc/cloud/cloud.cfg.d/10_tinkerbell.cfg
              DIRMODE: "0700"
              FS_TYPE: ext4
              GID: "0"
              MODE: "0600"
              UID: "0"'

	# Add Cloud-Init DS-Identity action
	actions_yaml+='

          - name: "Add Cloud-Init DS-Identity"
            image: quay.io/tinkerbell/actions/writefile:latest
            timeout: 90
            environment:
              DEST_DISK: {{ formatPartition ( index .Hardware.Disks 0 ) 1 }}
              FS_TYPE: ext4
              DEST_PATH: /etc/cloud/ds-identify.cfg
              UID: 0
              GID: 0
              MODE: 0600
              DIRMODE: 0700
              CONTENTS: |
                datasource: Ec2'

	# Write Netplan action
	actions_yaml+='

          - name: "Write Netplan"
            image: quay.io/tinkerbell/actions/writefile:latest
            timeout: 90
            environment:
              DEST_DISK: {{ index .Hardware.Disks 0 }}1
              FS_TYPE: ext4
              DEST_PATH: /etc/netplan/config.yaml
              CONTENTS: |
                network:
                  version: 2
                  renderer: networkd
                  ethernets:
                    id0:
                      match:
                        name: en*
                      dhcp4: true
              UID: 0
              GID: 0
              MODE: 0644
              DIRMODE: 0755'

	# Conditionally add Kexec action
	if [ "$enable_kexec" = "true" ]; then
		actions_yaml+='

          - name: "Kexec Into OS"
            image: ghcr.io/jacobweinstock/waitdaemon:latest
            timeout: 90
            pid: host
            environment:
              BLOCK_DEVICE: {{ formatPartition ( index .Hardware.Disks 0 ) 1 }}
              FS_TYPE: ext4
              IMAGE: quay.io/tinkerbell/actions/kexec:latest
              WAIT_SECONDS: 10
            volumes:
              - /var/run/docker.sock:/var/run/docker.sock'
	fi

	# Create the complete YAML
	cat << EOF | kubectl apply -f -
apiVersion: "tinkerbell.org/v1alpha1"
kind: Template
metadata:
  name: $template_name
  namespace: $NAMESPACE
spec:
  data: |
    version: "0.1"
    name: $template_name
    global_timeout: 1800
    tasks:
      - name: "OS Installation"
        worker: "{{.device_1}}"
        volumes:
          - /dev:/dev
          - /dev/console:/dev/console
          - /lib/firmware:/lib/firmware:ro
        actions:$actions_yaml
EOF

	echo "Template $template_name created successfully"
}

# Create templates
create_templates()
{
	echo -e "\nCreating templates ..."

	create_template true "$TEMPLATE_NAME_KEXEC"
	create_template false "$TEMPLATE_NAME_NOKEXEC"

	echo -e "\nTemplates created successfully:"
	echo "  - $TEMPLATE_NAME_KEXEC (with kexec step)"
	echo "  - $TEMPLATE_NAME_NOKEXEC (without kexec step)"
}

# Create image download resources
create_image_download()
{
	echo -e "\nCreating image download resources ..."

	echo -e "\nCreating ConfigMap for image download script ..."
	cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: download-image
  namespace: $NAMESPACE
data:
  entrypoint.sh: |-
    #!/usr/bin/env bash
    # This script is designed to download a cloud image file (.img) and then convert it to a .raw.gz file.
    # This is purpose built so non-raw cloud image files can be used with the "image2disk" action.
    set -euxo pipefail
    if ! which pigz qemu-img &>/dev/null; then
    	apk add --update pigz qemu-img
    fi
    image_url=\$1
    file=\$2/\${image_url##*/}
    file=\${file%.*}.raw.gz
    if [[ ! -f "\$file" ]]; then
    	wget "\$image_url" -O image.img
    	qemu-img convert -O raw image.img image.raw
    	pigz < image.raw > "\$file"
    	rm -f image.img image.raw
    fi
EOF

	echo -e "\nCreating Job to download Ubuntu Jammy image ..."
	cat << EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: download-ubuntu-jammy
  namespace: $NAMESPACE
spec:
  template:
    spec:
      containers:
        - name: download-ubuntu-jammy
          image: bash:latest
          command: ["/script/entrypoint.sh"]
          args:
            [
              "https://cloud-images.ubuntu.com/daily/server/jammy/current/jammy-server-cloudimg-amd64.img",
              "/output",
            ]
          volumeMounts:
            - mountPath: /output
              name: hook-artifacts
            - mountPath: /script
              name: configmap-volume
      restartPolicy: OnFailure
      volumes:
        - name: hook-artifacts
          hostPath:
            path: /tmp
            type: DirectoryOrCreate
        - name: configmap-volume
          configMap:
            defaultMode: 0700
            name: download-image
EOF

	echo -e "\nImage download resources created successfully"
}

# Wait for image download job to complete
wait_for_image_download()
{
	echo -e "\nWaiting for Ubuntu image download to complete ..."

	if kubectl wait --for=condition=complete job/download-ubuntu-jammy -n $NAMESPACE --timeout=1200s; then
		echo "Ubuntu image download completed successfully"
		return 0
	else
		local job_failed=$(kubectl get job download-ubuntu-jammy -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2> /dev/null || echo "")
		if [ "$job_failed" = "True" ]; then
			echo "Ubuntu image download failed"
		else
			echo "Timeout waiting for image download (20 minutes)"
		fi

		echo "Job status:"
		kubectl get job download-ubuntu-jammy -n $NAMESPACE
		echo "Recent job logs:"
		kubectl logs job/download-ubuntu-jammy -n $NAMESPACE --tail=10
		return 1
	fi
}

# Create a single workflow for a VM (netboot mode)
create_workflow_netboot()
{
	local vm_name=$1
	local vm_mac=$2
	local template_name=$3

	echo -e "\nCreating netboot workflow for $vm_name using template $template_name ..."
	echo "Boot mode: netboot (PXE/iPXE network boot)"

	cat << EOF | kubectl apply -f -
apiVersion: "tinkerbell.org/v1alpha1"
kind: Workflow
metadata:
  name: ${vm_name}-netboot-workflow
  namespace: $NAMESPACE
spec:
  disabled: true
  templateRef: $template_name
  hardwareRef: $vm_name
  hardwareMap:
    device_1: $vm_mac
  bootOptions:
    toggleAllowNetboot: true
    bootMode: netboot
EOF

	echo "Netboot workflow ${vm_name}-netboot-workflow created with template $template_name"
}

# Create a single workflow for a VM (customboot mode)
create_workflow_customboot()
{
	local vm_name=$1
	local vm_mac=$2
	local template_name=$3
	local efi_boot=${4:-true}

	echo -e "\nCreating customboot workflow for $vm_name using template $template_name ..."
	echo "Boot mode: customboot (Custom boot sequence with power/boot device control)"
	echo "EFI Boot: $efi_boot"

	cat << EOF | kubectl apply -f -
apiVersion: "tinkerbell.org/v1alpha1"
kind: Workflow
metadata:
  name: ${vm_name}-customboot-workflow
  namespace: $NAMESPACE
spec:
  disabled: true
  templateRef: $template_name
  hardwareRef: $vm_name
  hardwareMap:
    device_1: $vm_mac
  bootOptions:
    bootMode: customboot
    custombootConfig:
      preparingActions:
      - powerAction: "off"
      - bootDevice:
          device: "pxe"
          efiBoot: $efi_boot
      - powerAction: "on"
      postActions:
      - powerAction: "off"
      - bootDevice:
          device: "disk"
          persistent: true
          efiBoot: $efi_boot
      - powerAction: "on"
EOF

	echo "Customboot workflow ${vm_name}-customboot-workflow created with template $template_name (EFI: $efi_boot)"
}

# Create a single workflow for a VM (isoboot mode with Redfish BMC)
create_workflow_isoboot()
{
	local vm_name=$1
	local vm_mac=$2
	local template_name=$3

	echo -e "\nCreating isoboot workflow for $vm_name using template $template_name ..."
	echo "Boot mode: isoboot (ISO mounted via BMC virtual media)"

	# Convert MAC address to dash-delimited format for ISO URL
	local mac_dashed=$(echo "$vm_mac" | tr ':' '-')

	cat << EOF | kubectl apply -f -
apiVersion: "tinkerbell.org/v1alpha1"
kind: Workflow
metadata:
  name: ${vm_name}-isoboot-workflow
  namespace: $NAMESPACE
spec:
  disabled: true
  templateRef: $template_name
  hardwareRef: $vm_name
  hardwareMap:
    device_1: $vm_mac
  bootOptions:
    bootMode: isoboot
    isoURL: http://${TINKERBELL_LB_IP}:7171/iso/${mac_dashed}/hook.iso
EOF

	echo "Isoboot workflow ${vm_name}-isoboot-workflow created with template $template_name"
	echo "ISO URL: http://${TINKERBELL_LB_IP}:7171/iso/${mac_dashed}/hook.iso"
}

# Enable workflow and attach to VM console
enable_vm_and_attach()
{
	local vm_name=$1
	if [ -z "$vm_name" ]; then
		echo "Error: VM name is required"
		exit 1
	fi

	# Determine which workflow exists for this VM
	local workflow_name=""
	local netboot_workflow="${vm_name}-netboot-workflow"
	local customboot_workflow="${vm_name}-customboot-workflow"
	local isoboot_workflow="${vm_name}-isoboot-workflow"

	if kubectl -n $NAMESPACE get workflow "$netboot_workflow" &> /dev/null; then
		workflow_name="$netboot_workflow"
		echo "Found netboot workflow: $workflow_name"
	elif kubectl -n $NAMESPACE get workflow "$customboot_workflow" &> /dev/null; then
		workflow_name="$customboot_workflow"
		echo "Found customboot workflow: $workflow_name"
	elif kubectl -n $NAMESPACE get workflow "$isoboot_workflow" &> /dev/null; then
		workflow_name="$isoboot_workflow"
		echo "Found isoboot workflow: $workflow_name"
	else
		echo "Error: No workflow found for VM $vm_name"
		echo "Expected workflows: $netboot_workflow, $customboot_workflow, or $isoboot_workflow"
		exit 1
	fi

	echo "Enabling workflow $workflow_name for $vm_name ..."
	if ! kubectl -n $NAMESPACE patch workflow "$workflow_name" --type='merge' -p '{"spec":{"disabled":false}}'; then
		echo "Error: Failed to enable workflow $workflow_name"
		exit 1
	fi

	echo -e "\nWaiting up to 60 seconds for VM $vm_name to autostart ..."
	local timeout=60
	local start_time=$(date +%s)
	local vm_started=false

	while true; do
		local elapsed=$(($(date +%s) - start_time))

		if virsh domstate "$vm_name" 2> /dev/null | grep -q "running"; then
			vm_started=true
			break
		fi

		if [ $elapsed -ge $timeout ]; then
			break
		fi
	done

	if [ "$vm_started" = true ]; then
		virsh console "$vm_name"
	else
		echo -e "\nVM $vm_name did not autostart, starting manually ..."
		if ! virsh start "$vm_name" --console; then
			echo "Error: Failed to start VM $vm_name manually"
			exit 1
		fi
	fi
}

create_workflows()
{
	echo -e "\nCreating Tinkerbell workflows for VM provisioning ..."

	create_workflow_netboot "$VM1_NAME" "$VM1_MAC" "$TEMPLATE_NAME_KEXEC"
	create_workflow_customboot "$VM2_NAME" "$VM2_MAC" "$TEMPLATE_NAME_NOKEXEC" true
	create_workflow_isoboot "$VM3_NAME" "$VM3_MAC" "$TEMPLATE_NAME_KEXEC"

	echo -e "\nWorkflows created successfully:"
	echo "${VM1_NAME}-netboot-workflow (netboot) -> Hardware: $VM1_NAME (MAC: $VM1_MAC) -> Template: $TEMPLATE_NAME_KEXEC"
	echo "${VM2_NAME}-customboot-workflow (customboot) -> Hardware: $VM2_NAME (MAC: $VM2_MAC) -> Template: $TEMPLATE_NAME_NOKEXEC"
	echo "${VM3_NAME}-isoboot-workflow (isoboot) -> Hardware: $VM3_NAME (MAC: $VM3_MAC) -> Template: $TEMPLATE_NAME_KEXEC"
	echo "Status: Disabled (workflows will not run until enabled)"
}

# Main execution
main()
{
	parse_args "$@"

	check_prerequisites
	set_config

	if [ -n "$ENABLE_VM" ]; then
		enable_vm_and_attach "$ENABLE_VM"
		exit 0
	fi

	cleanup_all
	if [ "$CLEANUP_ONLY" = true ]; then
		exit 0
	fi

	echo -e "\nStarting LAB setup ..."

	create_storage_pool
	setup_kind_config
	create_kind_cluster
	set_network_config

	echo -e "\nUsing CNI provider: ${CNI_PROVIDER}"
	if [ "$CNI_PROVIDER" = "calico" ]; then
		get_calico_version
		install_calico
	elif [ "$CNI_PROVIDER" = "kube-router" ]; then
		get_kube_router_version
		install_kube_router
	else
		echo "Error: Unsupported CNI provider: $CNI_PROVIDER"
		exit 1
	fi

	wait_for_nodes
	set_network_ips
	configure_bridge_interface
	get_tinkerbell_version
	setup_tinkerbell_config
	install_tinkerbell
	create_vms
	create_templates
	create_image_download
	wait_for_image_download
	create_workflows

	echo -e "\nLAB setup complete!"

	echo -e "\nDebug Libvirt-IPMI:"
	echo -e "\tdocker run --rm -it --network kind alpine sh -c \"apk add --no-cache ipmitool && ipmitool -I lanplus -H $GATEWAY_IP -P $(echo $BMC_PASS_BASE64 | base64 -d) -U cirros mc info\""

	echo -e "\nDebug Redfish BMC:"
	echo -e "\tcurl -k -u admin:$(echo $REDFISH_PASS_BASE64 | base64 -d) https://$REDFISH_IP:$REDFISH_PORT/redfish/v1/Systems/"

	echo -e "\nMonitor workflows:"
	echo -e "\tkubectl -n $NAMESPACE get workflows"

	echo -e "\nTo enable and start provisioning:"
	echo -e "\tkubectl -n $NAMESPACE patch workflow ${VM1_NAME}-netboot-workflow --type='merge' -p '{\"spec\":{\"disabled\":false}}'"
	echo -e "\tkubectl -n $NAMESPACE patch workflow ${VM2_NAME}-customboot-workflow --type='merge' -p '{\"spec\":{\"disabled\":false}}'"
	echo -e "\tkubectl -n $NAMESPACE patch workflow ${VM3_NAME}-isoboot-workflow --type='merge' -p '{\"spec\":{\"disabled\":false}}'"

	echo -e "\nTo attach to VM console (after workflow starts the VM):"
	echo -e "\tvirsh console $VM1_NAME"
	echo -e "\tvirsh console $VM2_NAME"
	echo -e "\t# Note: $VM3_NAME uses isoboot which doesn't expose serial console"
	echo -e "\t# Use VNC instead: virt-viewer $VM3_NAME or connect to VNC port"
	echo -e "\t(Use Ctrl+] to disconnect from console)"

	echo -e "\nAlternatively, use the script to enable and attach in one command:"
	echo -e "\t$0 --enable-and-attach DOMAIN_NAME"
	echo -e "\t# Note: For isoboot VMs, use VNC instead of console attach"
}

# Execute main function with all arguments
main "$@"
