# VM execution logs

[ignite-lifecycle.ps1](./ignite-lifecycle.ps1) uses Custom Script Extension to
execute cluster installation and Arc onboarding as root, without switching users.
Cloud-init also installs the tools and Azure CLI extensions as root. All three
shell scripts require root and set `HOME=/root`, including when invoked with sudo.
Kubeconfig is stored at `/root/.kube/config`; Azure CLI extensions and login state
use `/root/.azure`. No Docker group membership is required for provisioning.
The cluster script waits for cloud-init with
`timeout 1800 cloud-init status --wait --long`, as root, after enabling its
fixed log and before checking prerequisites. Exit code 2 (recoverable errors)
logs a warning and continues to prerequisite checks; the detailed cloud-init
status remains in the cluster log. All other nonzero exit codes stop installation,
including fatal errors (1) and the 30-minute wait timeout (124). Continuing does
not repair bootstrap problems; missing tools or other unmet prerequisites still
stop installation. Onboarding runs only if cluster installation succeeds.

The cluster script must already have been downloaded before the lifecycle invokes
it. Moving the wait into that script does not handle invocation before the script
exists. Do not invoke the cluster script from cloud-init itself, as it would wait
for its own caller to finish.

The lifecycle script has no custom logging wrapper or per-phase log directories.
Command output is returned through the extension and may be truncated by Azure
or Skillable.

For bootstrap problems, inspect `sudo cloud-init status --long`,
`/var/log/cloud-init-output.log`, and `/var/log/cloud-init.log` on the VM.
The tool installer also writes `/var/log/arc-k8s-demo-install-tools.log`.
Arc onboarding retains its own step logs under
`/root/.local/state/onboard-k8s-to-arc/` and prints their location.

Cluster installation and onboarding also append stdout and stderr to fixed files
under root's home directory:

```text
/root/arc-k8s-demo-logs/install-kind-cluster.log
/root/arc-k8s-demo-logs/onboard-k8s-to-arc.log
```

An administrator with sudo privileges can debug without changing file permissions:

```bash
sudo docker ps
sudo kind get clusters
sudo kubectl --kubeconfig=/root/.kube/config get pods -A
sudo tail -n 100 /root/arc-k8s-demo-logs/install-kind-cluster.log
sudo tail -n 100 /root/arc-k8s-demo-logs/onboard-k8s-to-arc.log
```

Deploy the updated tool installer and both cluster/onboarding scripts together.
On an existing VM prepared with the administrator-based installer, run the updated
tool installer with sudo first to install Azure CLI extensions for root. Existing
administrator-owned logs and Azure CLI state are not moved. With the same cluster
name and Docker daemon, the cluster installer can reuse the existing kind cluster
and export a fresh kubeconfig for root.

Each run begins with a UTC timestamp. Cluster messages and onboarding step-start
messages include timestamps; raw tool output is preserved without modification.
Onboarding copies full step output into its fixed log, including successful
commands, while keeping successful step output off the console. Failure excerpts
can appear twice in the fixed log: once in full step output and once in the
console summary.

The directory is private (0700), and the files are private (0600). Existing logs
are appended, not replaced; no rotation is configured. Do not execute concurrent
runs of the same script, as their output would interleave. Logs survive reruns and
VM reboots, but not deletion of the VM's disk. Console output can still be
truncated by the extension or Skillable. These logs begin only when the scripts
execute. The cluster log captures detailed cloud-init status, not the full earlier
bootstrap output; use the cloud-init logs listed above for that output.

The cluster installer reuses a kind cluster with the exact configured name by
exporting its kubeconfig again, restoring private file permissions, and checking
API access with a 30-second request timeout. It selects the cluster context once
in the shared kubeconfig; subsequent kubectl and Helm commands use that current
context. Do not switch that kubeconfig's context concurrently during installation.
A missing cluster is created as
before. An inaccessible existing cluster is not deleted or recreated.

Keep the same instance GUID/cluster name when retrying the same lab. Reuse does
not validate or reconcile the existing cluster's Kubernetes version, topology,
or networking configuration.

Calico uses the official Tigera operator Helm chart, pinned to v3.29.3, with
release name `calico` in namespace `tigera-operator`. Its values preserve the
previous manifest's IP pool (192.168.0.0/16, block size 26, VXLANCrossSubnet,
outgoing NAT enabled, all nodes) and enable the Calico API server. The pool CIDR
matches the kind pod subnet.

`helm upgrade --install --atomic --timeout 10m` installs or updates that release.
In Helm 3, atomic mode enables waiting, removes a failed initial release, and
rolls back a failed upgrade. This is not a transaction covering all Calico
resources: Helm does not roll back CRDs or necessarily clean up operator-created
resources. The subsequent node and Calico workload checks remain necessary;
their failures occur after Helm returns and do not trigger Helm's atomic rollback.

Existing manifest-installed Calico resources are not automatically adopted.
Helm can report ownership conflicts; do not bypass them with forced takeover.
Use a fresh lab cluster or a separately reviewed migration for those installations.
Helm also does not automatically upgrade CRDs from a chart's `crds` directory;
future Calico version changes require review of its upgrade instructions.

This does not make the entire workflow idempotent. Transient retries, recovery
from partial operator reconciliation, and Arc onboarding idempotency are separate
changes.
