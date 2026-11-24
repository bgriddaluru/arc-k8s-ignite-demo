#!/usr/bin/env bash
# Requires an existing kind cluster and the tools/settings installed by cloud-init.
# Run as root (or with sudo), after install-kind-cluster.sh.
set -Eeuo pipefail

if (( EUID != 0 )); then
    echo "Run this script as root (or with sudo) to onboard the cluster to Arc." >&2
    exit 1
fi

export HOME=/root

umask 077
execution_log_dir="$HOME/arc-k8s-demo-logs"
mkdir -p "$execution_log_dir"
chmod 0700 "$execution_log_dir"
execution_log="$execution_log_dir/onboard-k8s-to-arc.log"
touch "$execution_log"
chmod 0600 "$execution_log"
exec > >(tee -a "$execution_log") 2>&1
printf '\n=== Arc onboarding started: %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

trap 'rc=$?; echo "Arc setup failed at line $LINENO (exit $rc)." >&2; exit "$rc"' ERR

for tool in jq az kubectl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool is missing. Install it before running this script." >&2
        exit 1
    fi
done

settings=/etc/arc-k8s-demo.json

umask 077
mkdir -p "$HOME/.local/state/onboard-k8s-to-arc"
log_dir=$(mktemp -d "$HOME/.local/state/onboard-k8s-to-arc/run.XXXXXX")
step_number=0
echo "Full onboarding logs: $log_dir"

run_step() {
    local description=$1
    shift
    step_number=$((step_number + 1))
    local step_log="$log_dir/step-$step_number.log"
    printf '[%s] Running: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$description"
    if "$@" >"$step_log" 2>&1; then
        cat "$step_log" >>"$execution_log"
        echo "Completed: $description"
    else
        local rc=$?
        cat "$step_log" >>"$execution_log"
        printf 'FAILED: %s (exit %s).\n' "$description" "$rc" >&2
        tail -c 2500 "$step_log" >&2
        printf '\nFull step log: %s\n' "$step_log" >&2
        exit "$rc"
    fi
}

cluster_name=$(jq -er '.clusterName' "$settings")
subscription_id=$(jq -er '.subscriptionId' "$settings")
resource_group=$(jq -er '.resourceGroupName' "$settings")
location=$(jq -er '.location' "$settings")
identity_client_id=$(jq -er '.managedIdentityClientId' "$settings")
export KUBECONFIG="$HOME/.kube/config"
export AZURE_CONFIG_DIR="$HOME/.azure"

if [[ ! "$cluster_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Invalid clusterName: use lowercase letters, digits and hyphens, starting and ending with a letter or digit." >&2
    exit 1
fi

run_step "Securing kubeconfig" chmod 0600 "$KUBECONFIG"
run_step "Selecting kind context" kubectl config use-context "kind-$cluster_name"
run_step "Waiting for Kubernetes nodes" kubectl wait --for=condition=Ready nodes --all --timeout=300s
run_step "Listing Kubernetes nodes" kubectl get nodes

run_step "Managed identity login" az login --identity --client-id "$identity_client_id" --output none
run_step "Selecting Azure subscription" az account set --subscription "$subscription_id"
run_step "Connecting cluster to Azure Arc" az connectedk8s connect --name "$cluster_name" --resource-group "$resource_group" \
    --location "$location" --output none

run_step "Installing Kubernetes Upgrade Insights" az k8s-extension create --cluster-type connectedClusters --cluster-name "$cluster_name" \
    --resource-group "$resource_group" --extension-type microsoft.kubernetesupgradeinsights \
    --name k8s-upgrade-insights-ext --output none

echo "Arc onboarding and extension creation commands completed for $cluster_name."
