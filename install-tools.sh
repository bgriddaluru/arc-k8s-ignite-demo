#!/usr/bin/env bash
# Run as root on Ubuntu 24.04 amd64 after cloud-init creates /etc/arc-k8s-demo.json.
# Requires cloud-init's prerequisite packages: ca-certificates, curl, gnupg, jq, tar.
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "Run this script as root (or with sudo) to install tools and enable services." >&2
    exit 1
fi

umask 022
exec > >(tee -a /var/log/arc-k8s-demo-install-tools.log) 2>&1
trap 'rc=$?; echo "Tool installation failed at line $LINENO (exit $rc). See /var/log/arc-k8s-demo-install-tools.log" >&2; exit "$rc"' ERR

settings=/etc/arc-k8s-demo.json
admin_user=$(jq -er '.adminUsername' "$settings")
kind_version=$(jq -er '.kindVersion' "$settings")
helm_version=$(jq -er '.helmVersion' "$settings")
kubernetes_version=$(jq -er '.kubernetesVersion' "$settings")

. /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
    echo "This installer supports Ubuntu 24.04 only." >&2
    exit 1
fi
arch=$(dpkg --print-architecture)
if [[ "$arch" != amd64 ]]; then
    echo "Select an x64 VM size; this installer supports amd64 only." >&2
    exit 1
fi
admin_home=$(getent passwd "$admin_user" | cut -d: -f6)
admin_group=$(id -gn "$admin_user")
test -d "$admin_home"

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
cd "$work_dir"
download() {
    curl --fail --show-error --silent --location --retry 5 --retry-all-errors \
        --connect-timeout 20 --max-time 300 "$1" --output "$2"
}

install -m 0755 -d /etc/apt/keyrings
download https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

download https://packages.microsoft.com/keys/microsoft.asc microsoft.asc
gpg --batch --yes --dearmor --output /etc/apt/keyrings/microsoft.gpg microsoft.asc
chmod 0644 /etc/apt/keyrings/microsoft.gpg
cat > /etc/apt/sources.list.d/azure-cli.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: noble
Components: main
Architectures: $arch
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin azure-cli
systemctl enable --now docker.service containerd.service
for service_name in docker.service containerd.service; do
    systemctl is-active --quiet "$service_name"
    systemctl is-enabled --quiet "$service_name"
done
usermod -aG docker "$admin_user"

download "https://github.com/kubernetes-sigs/kind/releases/download/$kind_version/kind-linux-$arch" kind
download "https://github.com/kubernetes-sigs/kind/releases/download/$kind_version/kind-linux-$arch.sha256sum" kind.sha256sum
echo "$(awk '{print $1}' kind.sha256sum)  kind" | sha256sum --check -
install -o root -g root -m 0755 kind /usr/local/bin/kind

download "https://dl.k8s.io/release/$kubernetes_version/bin/linux/$arch/kubectl" kubectl
download "https://dl.k8s.io/release/$kubernetes_version/bin/linux/$arch/kubectl.sha256" kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check -
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

helm_archive="helm-$helm_version-linux-$arch.tar.gz"
download "https://get.helm.sh/$helm_archive" "$helm_archive"
download "https://get.helm.sh/$helm_archive.sha256sum" helm.sha256sum
sha256sum --check helm.sha256sum
tar -xzf "$helm_archive"
install -o root -g root -m 0755 "linux-$arch/helm" /usr/local/bin/helm

install -d -o "$admin_user" -g "$admin_group" -m 0700 "$admin_home/.kube"
install -d -o "$admin_user" -g "$admin_group" -m 0700 "$admin_home/.azure"
as_admin() {
    runuser -u "$admin_user" -- env HOME="$admin_home" \
        AZURE_CONFIG_DIR="$admin_home/.azure" KUBECONFIG="$admin_home/.kube/config" \
        KIND_EXPERIMENTAL_PROVIDER=docker "$@"
}

as_admin docker info
as_admin kind version
as_admin kubectl version --client
as_admin helm version --short
as_admin az version

for extension_name in connectedk8s k8s-extension; do
    echo "Installing Azure CLI extension: $extension_name"
    as_admin az extension add --name "$extension_name" --upgrade --yes
    as_admin az extension show --name "$extension_name" --query '{name:name, version:version}' --output json
done

echo "Tool installation completed. Docker and containerd are enabled and running."
echo "Run cluster installation and Arc onboarding as $admin_user without sudo."
