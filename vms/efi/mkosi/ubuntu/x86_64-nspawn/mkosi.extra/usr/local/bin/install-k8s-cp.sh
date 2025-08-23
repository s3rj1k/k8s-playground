#!/bin/bash
#
# Kubernetes control plane initialization script
# Initializes a Kubernetes control plane using kubeadm
#

set -euo pipefail

# Set environment variables
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

echo "Initializing Kubernetes control plane..."

# Reset any existing cluster configuration
echo "Resetting any existing cluster configuration..."
kubeadm reset --force

# Ensure /dev/kmsg exists for proper logging
echo "Checking /dev/kmsg..."
if [[ ! -e /dev/kmsg ]]; then
	echo "Creating symlink /dev/kmsg -> /dev/console"
	ln -s /dev/console /dev/kmsg
fi

# Initialize the control plane
echo "Initializing control plane with kubeadm..."
if ! kubeadm init --config /etc/kubeadm/init.yaml --ignore-preflight-errors All; then
	echo "Error: Failed to initialize Kubernetes control plane"
	exit 1
fi

# Wait for API server to be ready
echo "Waiting for API server to be ready..."
until kubectl --kubeconfig "$KUBECONFIG" cluster-info > /dev/null 2>&1; do
	echo "Waiting for API server..."
	sleep 5
done

# Remove control-plane taints to allow pods on control plane nodes
echo "Removing control-plane taints to allow pods on control plane nodes..."
if ! kubectl --kubeconfig "$KUBECONFIG" taint nodes --all node-role.kubernetes.io/control-plane-; then
	echo "Warning: Failed to remove control-plane taints (this may be normal if already removed)"
fi

echo "Kubernetes control plane initialization completed successfully!"

# Show cluster info
echo "Cluster information:"
kubectl --kubeconfig "$KUBECONFIG" cluster-info

echo ""
echo "Node status:"
kubectl --kubeconfig "$KUBECONFIG" get nodes
