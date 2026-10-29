#!/usr/bin/env bash
# Requires Docker (Linux containers), kind >= 0.27.0, kubectl 1.32.x, and Helm 3.
# Run as a user with Docker access. Historical versions are for demo use only.
set -Eeuo pipefail

CLUSTER_NAME="compatibility-demo"
KUBERNETES_IMAGE="kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f"
CALICO_VERSION="v3.29.3"
ISTIO_VERSION="1.25.2"
CERT_MANAGER_VERSION="v1.19.1"
PROMETHEUS_CHART_VERSION="27.11.0" # Installs Prometheus v3.3.0.
CONTEXT="kind-$CLUSTER_NAME"

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

trap 'rc=$?; log "ERROR at line $LINENO (exit $rc): $BASH_COMMAND" >&2; exit "$rc"' ERR

log "Checking prerequisites."
for tool in docker kind kubectl helm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "ERROR: $tool is missing. Install it before running this script." >&2
        exit 1
    fi
done

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
while IFS= read -r cluster; do
    if [[ "$cluster" == "$CLUSTER_NAME" ]]; then
        log "ERROR: Cluster $CLUSTER_NAME already exists. This script will not replace it." >&2
        exit 1
    fi
done <<< "$existing_clusters"

log "Creating Kubernetes 1.32.2: one control plane and two workers."
# Do not wait for Ready here: nodes need Calico before they can become Ready.
kind create cluster --name "$CLUSTER_NAME" --image "$KUBERNETES_IMAGE" --wait 0s --config - <<'YAML'
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

log "Installing Calico $CALICO_VERSION as the only CNI."
kubectl --context "$CONTEXT" create -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml"
kubectl --context "$CONTEXT" wait --for=condition=Established crd/installations.operator.tigera.io --timeout=120s
kubectl --context "$CONTEXT" create -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/custom-resources.yaml"
kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=600s
kubectl --context "$CONTEXT" rollout status daemonset/calico-node -n calico-system --timeout=300s
kubectl --context "$CONTEXT" wait --for=condition=Available deployment --all -n calico-system --timeout=300s
kubectl --context "$CONTEXT" rollout status deployment/coredns -n kube-system --timeout=300s

log "Installing Istio $ISTIO_VERSION CRDs and control plane."
helm upgrade --install istio-base base \
    --repo https://istio-release.storage.googleapis.com/charts \
    --version "$ISTIO_VERSION" --kube-context "$CONTEXT" \
    --namespace istio-system --create-namespace \
    --set defaultRevision=default --wait --timeout 10m
helm upgrade --install istiod istiod \
    --repo https://istio-release.storage.googleapis.com/charts \
    --version "$ISTIO_VERSION" --kube-context "$CONTEXT" \
    --namespace istio-system --wait --timeout 10m

log "Installing cert-manager $CERT_MANAGER_VERSION, including CRDs."
helm upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io \
    --version "$CERT_MANAGER_VERSION" --kube-context "$CONTEXT" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 10m

log "Installing Prometheus 3.3.0 (chart $PROMETHEUS_CHART_VERSION)."
# Ephemeral storage and no optional add-ons keep the local demo small.
helm upgrade --install prometheus prometheus \
    --repo https://prometheus-community.github.io/helm-charts \
    --version "$PROMETHEUS_CHART_VERSION" --kube-context "$CONTEXT" \
    --namespace monitoring --create-namespace \
    --set server.persistentVolume.enabled=false \
    --set alertmanager.enabled=false \
    --set kube-state-metrics.enabled=false \
    --set prometheus-node-exporter.enabled=false \
    --set prometheus-pushgateway.enabled=false \
    --wait --timeout 10m

log "Verifying installed workloads."
kubectl --context "$CONTEXT" rollout status deployment/istiod -n istio-system --timeout=300s
kubectl --context "$CONTEXT" wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
kubectl --context "$CONTEXT" rollout status deployment/prometheus-server -n monitoring --timeout=300s
kubectl --context "$CONTEXT" get nodes -o wide
helm list --kube-context "$CONTEXT" --all-namespaces
kubectl --context "$CONTEXT" get pods -A \
    -o 'custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,IMAGES:.spec.containers[*].image'

log "Done. Cluster: $CLUSTER_NAME. Context: $CONTEXT."
log "Istio control plane is installed; application sidecar injection is not enabled."
log "For target Kubernetes 1.33: Calico is untested; Istio is outside recorded support; cert-manager and Prometheus are compatible per the dataset."
log "This script does not perform an upgrade, Arc onboarding, or runtime compatibility tests on 1.33."