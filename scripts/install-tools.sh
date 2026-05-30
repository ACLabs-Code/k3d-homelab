#!/usr/bin/env bash
set -euo pipefail

# macOS arm64 only
OS="darwin"
ARCH="arm64"

echo "Installing kubectl..."
KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
echo "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client) installed."

echo "Installing k3d..."
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
echo "k3d $(k3d version) installed."

echo ""
echo "Done. Verify with: kubectl version --client && k3d version"
echo "Or install via Homebrew: brew install kubectl k3d"
