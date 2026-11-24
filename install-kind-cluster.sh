#!/usr/bin/env bash
# Requires Docker (Linux containers), kind >= 0.27.0, kubectl 1.32.x, and Helm 3.
# Run as root (or with sudo).
# Historical versions are for demo use only. Kubeconfig is shared at /root/.kube/config.
# Existing kind clusters and Helm-managed Calico releases are reused.
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "Run this script as root (or with sudo) to install the cluster." >&2
    exit 1
fi

export HOME=/root
export KIND_EXPERIMENTAL_PROVIDER=docker

umask 077
log_dir="$HOME/arc-k8s-demo-logs"
mkdir -p "$log_dir"
chmod 0700 "$log_dir"
execution_log="$log_dir/install-kind-cluster.log"
touch "$execution_log"
chmod 0600 "$execution_log"
exec > >(tee -a "$execution_log") 2>&1
printf '\n=== Cluster installation started: %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

export KUBECONFIG="$HOME/.kube/config"
KUBERNETES_IMAGE="kindest/node:v1.32.2"
CALICO_VERSION="v3.29.3"
ISTIO_VERSION="1.25.2"
CERT_MANAGER_VERSION="v1.19.1"
PROMETHEUS_CHART_VERSION="27.11.0" # Installs Prometheus v3.3.0.

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

trap 'rc=$?; log "ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit "$rc"' ERR

log "Waiting for cloud-init to finish."
if timeout 1800 cloud-init status --wait --long; then
    log "Cloud-init completed successfully."
else
    rc=$?
    if (( rc == 2 )); then
        log "WARNING: Cloud-init completed with recoverable errors (exit 2). Continuing with prerequisite checks; review the cloud-init status above."
    else
        log "ERROR: Cloud-init wait failed (exit $rc). Installation stopped; review the cloud-init status above and /var/log/cloud-init.log." >&2
        exit "$rc"
    fi
fi

log "Checking prerequisites."
for tool in jq docker kind kubectl helm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "ERROR: $tool is missing. Install it before running this script." >&2
        exit 1
    fi
done

settings=/etc/arc-k8s-demo.json
CLUSTER_NAME=$(jq -er '.clusterName | select(type == "string" and length > 0)' "$settings")
if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    log "ERROR: Invalid clusterName: use lowercase letters, digits and hyphens, starting and ending with a letter or digit." >&2
    exit 1
fi
CONTEXT="kind-$CLUSTER_NAME"

docker info
if [[ "$(docker info --format '{{.OSType}}')" != "linux" ]]; then
    log "ERROR: Docker must use Linux containers." >&2
    exit 1
fi

kind_version="$(kind version)"
if [[ ! "$kind_version" =~ v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    log "ERROR: Cannot determine kind version: $kind_version" >&2
    exit 1
fi
if (( BASH_REMATCH[1] == 0 && BASH_REMATCH[2] < 27 )); then
    log "ERROR: kind >= 0.27.0 is required." >&2
    exit 1
fi
log "$kind_version"
kubectl version --client
helm_version="$(helm version --short)"
if [[ "$helm_version" != v3.* ]]; then
    log "ERROR: This demo script requires Helm 3; found $helm_version." >&2
    exit 1
fi

existing_clusters="$(kind get clusters)"
cluster_exists=false
while IFS= read -r cluster; do
    if [[ "$cluster" == "$CLUSTER_NAME" ]]; then
        cluster_exists=true
        break
    fi
done <<< "$existing_clusters"

mkdir -p "$HOME/.kube"
if "$cluster_exists"; then
    log "Reusing existing cluster $CLUSTER_NAME and refreshing its kubeconfig."
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
else
    log "Creating Kubernetes 1.32.2: one control plane and two workers."
    # Do not wait for Ready here: nodes need Calico before they can become Ready.
    kind create cluster --name "$CLUSTER_NAME" --image "$KUBERNETES_IMAGE" --kubeconfig "$KUBECONFIG" --wait 0s --config - <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
YAML
fi

chmod 0600 "$KUBECONFIG"
kubectl config use-context "$CONTEXT"
log "Checking Kubernetes API access for $CONTEXT."
if kubectl --request-timeout=30s get --raw=/version >/dev/null; then
    log "Kubernetes API is accessible."
else
    rc=$?
    log "ERROR: Cannot access the API for $CONTEXT (exit $rc). Check the cluster containers and kubeconfig; this script will not delete or recreate the cluster." >&2
    exit "$rc"
fi
node_names=$(kind get nodes --name "$CLUSTER_NAME")
if [[ -z "$node_names" ]]; then
    log "ERROR: No containers found for cluster $CLUSTER_NAME." >&2
    exit 1
fi
readarray -t nodes <<< "$node_names"
docker update --restart=unless-stopped "${nodes[@]}"

log "Installing Calico $CALICO_VERSION as the only CNI."
helm upgrade --install calico tigera-operator \
    --repo https://docs.tigera.io/calico/charts \
    --version "$CALICO_VERSION" \
    --namespace tigera-operator --create-namespace \
    --atomic --timeout 10m --values - <<'YAML'
installation:
  enabled: true
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
apiServer:
  enabled: true
YAML
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl rollout status daemonset/calico-node -n calico-system --timeout=300s
kubectl wait --for=condition=Available deployment --all -n calico-system --timeout=300s
kubectl rollout status deployment/coredns -n kube-system --timeout=300s

log "Installing Istio $ISTIO_VERSION CRDs and control plane."
helm upgrade --install istio-base base \
    --repo https://istio-release.storage.googleapis.com/charts \
    --version "$ISTIO_VERSION" \
    --namespace istio-system --create-namespace \
    --set defaultRevision=default --wait --timeout 10m
helm upgrade --install istiod istiod \
    --repo https://istio-release.storage.googleapis.com/charts \
    --version "$ISTIO_VERSION" \
    --namespace istio-system --wait --timeout 10m

log "Installing cert-manager $CERT_MANAGER_VERSION, including CRDs."
helm upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io \
    --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 10m

log "Installing Prometheus 3.3.0 (chart $PROMETHEUS_CHART_VERSION)."
# Ephemeral storage and no optional add-ons keep the local demo small.
helm upgrade --install prometheus prometheus \
    --repo https://prometheus-community.github.io/helm-charts \
    --version "$PROMETHEUS_CHART_VERSION" \
    --namespace monitoring --create-namespace \
    --set server.persistentVolume.enabled=false \
    --set alertmanager.enabled=false \
    --set kube-state-metrics.enabled=false \
    --set prometheus-node-exporter.enabled=false \
    --set prometheus-pushgateway.enabled=false \
    --wait --timeout 10m

log "Verifying installed workloads."
kubectl rollout status deployment/istiod -n istio-system --timeout=300s
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
kubectl rollout status deployment/prometheus-server -n monitoring --timeout=300s
kubectl get nodes -o wide
helm list --all-namespaces
kubectl get pods -A \
    -o 'custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,IMAGES:.spec.containers[*].image'

log "Done. Cluster: $CLUSTER_NAME. Context: $CONTEXT."
log "Istio control plane is installed; application sidecar injection is not enabled."
log "For target Kubernetes 1.33: Calico is untested; Istio is outside recorded support; cert-manager and Prometheus are compatible per the dataset."
log "This script does not perform an upgrade, Arc onboarding, or runtime compatibility tests on 1.33."