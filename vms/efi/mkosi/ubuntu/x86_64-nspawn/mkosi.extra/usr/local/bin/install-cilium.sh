#!/bin/bash
#
# Cilium CNI installation script
# Based on https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/
#

set -euo pipefail

# Set environment variables
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
export HOME=${HOME:-/root}
export XDG_CACHE_HOME=${XDG_CACHE_HOME:-/root/.cache}

echo "Installing Cilium CNI..."

# Fetch Cilium CLI stable version
echo "Fetching Cilium CLI stable version..."
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt | tr -d '\n')
if [[ -z $CILIUM_CLI_VERSION ]]; then
	echo "Error: Failed to fetch Cilium CLI version"
	exit 1
fi

echo "Cilium CLI version: $CILIUM_CLI_VERSION"

# Fetch Cilium stable version
echo "Fetching Cilium stable version..."
CILIUM_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium/main/stable.txt | tr -d '\n')
if [[ -z $CILIUM_VERSION ]]; then
	echo "Error: Failed to fetch Cilium version"
	exit 1
fi

echo "Cilium version: $CILIUM_VERSION"

# Download and install Cilium CLI if not already present
if [[ ! -f /usr/local/bin/cilium ]]; then
	echo "Downloading and installing Cilium CLI $CILIUM_CLI_VERSION..."
	curl -L --fail "https://github.com/cilium/cilium-cli/releases/download/$CILIUM_CLI_VERSION/cilium-linux-amd64.tar.gz" |
		tar xzf - -C /usr/local/bin
	chmod +x /usr/local/bin/cilium
	echo "Cilium CLI installed successfully"
else
	echo "Cilium CLI already installed"
fi

# Check if Cilium is already installed
echo "Checking if Cilium is already installed..."
if cilium status --kubeconfig "$KUBECONFIG" > /dev/null 2>&1; then
	echo "Cilium is already installed and running"
	cilium status --kubeconfig "$KUBECONFIG"
	exit 0
fi

# Install Cilium
echo "Installing Cilium $CILIUM_VERSION..."
cilium install --version "$CILIUM_VERSION" --kubeconfig "$KUBECONFIG"

# Wait for Cilium to be ready
echo "Waiting for Cilium to be ready..."
cilium status --wait --kubeconfig "$KUBECONFIG"

echo "Cilium installation completed successfully!"
cilium status --kubeconfig "$KUBECONFIG"
