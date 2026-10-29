targetScope = 'resourceGroup'

@description('Azure region for the VM and related resources.')
param location string = resourceGroup().location

@description('Default Azure CLI subscription inside the VM. Defaults to the deployment subscription; the managed identity must have access if overridden. This does not change resource deployment or role assignment scope.')
param subscriptionId string = subscription().subscriptionId

@description('Resource group for Arc onboarding. Defaults to the deployment resource group. If overridden, it must already exist and the managed identity needs access; this does not change the role assignment scope.')
param resourceGroupName string = resourceGroup().name

@description('Base name for the VM and related resources.')
@minLength(1)
@maxLength(48)
param vmName string = 'arc-k8s-demo'

@description('An x64 VM size. Four vCPUs and 16 GiB RAM are recommended for this lab.')
param vmSize string = 'Standard_D4s_v5'

@description('Ubuntu administrator account. Azure Linux username restrictions apply.')
@minLength(1)
@maxLength(32)
param adminUsername string = 'azureuser'

@secure()
@description('Password for SSH login. The default is for disposable labs only; override it with a strong unique password before deployment.')
param adminPassword string = 'Password1234'

@description('Kind cluster name: lowercase letters, digits and hyphens; start and end with a letter or digit.')
@minLength(1)
@maxLength(40)
param clusterName string = 'arc-demo'

@description('Raw HTTPS URL of arc-k8s-demo-settings.json uploaded to Gist. Deployment-specific values are supplied by Bicep and take precedence over downloaded settings.')
@minLength(1)
param settingsUrl string = 'https://gist.github.com/bgriddaluru/4845aede7595e6eb11180d99902daf24/raw/settings.json'

@description('Optional tags shared by all resources.')
param tags object = {}

var commonTags = union({
  managedBy: 'bicep'
  workload: 'arc-k8s-demo'
}, tags)

var deploymentSettings = {
  adminUsername: adminUsername
  clusterName: clusterName
  subscriptionId: subscriptionId
  resourceGroupName: resourceGroupName
  location: location
  managedIdentityClientId: managedIdentity.properties.clientId
  settingsUrl: settingsUrl
}

// Base64-encoded JSON keeps parameter values out of YAML and shell syntax.
var cloudInitTemplate = '''
#cloud-config
ssh_pwauth: true
package_update: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - jq
  - tar
write_files:
  - path: /etc/arc-k8s-demo-deployment.json
    owner: root:root
    permissions: '0644'
    encoding: b64
    content: __DEPLOYMENT_SETTINGS__
  - path: /etc/apt/apt.conf.d/80-arc-k8s-demo-retries
    owner: root:root
    permissions: '0644'
    content: |
      Acquire::Retries "5";
      Acquire::http::Timeout "60";
      Acquire::https::Timeout "60";
  - path: /usr/local/bin/onboard-k8s-to-arc
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      trap 'rc=$?; echo "Arc setup failed at line $LINENO (exit $rc)." >&2; exit "$rc"' ERR

      settings=/etc/arc-k8s-demo.json
      admin_user=$(jq -er '.adminUsername' "$settings")
      if [[ "$(id -un)" != "$admin_user" ]]; then
        echo "Run this script as $admin_user without sudo so it uses the correct kubeconfig and Azure CLI configuration." >&2
        exit 1
      fi
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
        echo "Running: $description"
        if "$@" >"$step_log" 2>&1; then
          echo "Completed: $description"
        else
          local rc=$?
          printf 'FAILED: %s (exit %s).\n' "$description" "$rc" >&2
          tail -c 2500 "$step_log" >&2
          printf '\nFull step log: %s\n' "$step_log" >&2
          exit "$rc"
        fi
      }

      cluster_name=$(jq -er '.clusterName' "$settings")
      export KUBECONFIG="$HOME/.kube/config"
      export AZURE_CONFIG_DIR="$HOME/.azure"
      export KIND_EXPERIMENTAL_PROVIDER=docker

      if [[ ! "$cluster_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        echo "Invalid clusterName: use lowercase letters, digits and hyphens, starting and ending with a letter or digit." >&2
        exit 1
      fi

      run_step "Creating kind cluster $cluster_name" /usr/local/bin/install-kind-cluster.sh
      run_step "Onboarding cluster to Azure Arc" /usr/local/bin/onboard-k8s-to-arc.sh
      echo "Arc onboarding and extension creation commands completed for $cluster_name."
  - path: /usr/local/sbin/arc-k8s-demo-bootstrap
    owner: root:root
    permissions: '0750'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      umask 022
      exec > >(tee -a /var/log/arc-k8s-demo-bootstrap.log) 2>&1
      trap 'rc=$?; echo "Bootstrap failed at line $LINENO (exit $rc). See /var/log/arc-k8s-demo-bootstrap.log"; exit "$rc"' ERR

      deployment_settings=/etc/arc-k8s-demo-deployment.json
      admin_user=$(jq -er '.adminUsername' "$deployment_settings")
      subscription_id=$(jq -er '.subscriptionId' "$deployment_settings")
      identity_client_id=$(jq -er '.managedIdentityClientId' "$deployment_settings")
      . /etc/os-release
      if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
        echo "This bootstrap supports Ubuntu 24.04 only."
        exit 1
      fi
      arch=$(dpkg --print-architecture)
      if [[ "$arch" != amd64 ]]; then
        echo "Select an x64 VM size; this template uses an amd64 Ubuntu image."
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

      settings_url=$(jq -er '.settingsUrl' "$deployment_settings")
      if [[ "$settings_url" != https://* ]]; then
        echo "settingsUrl must be a raw HTTPS URL for the settings JSON." >&2
        exit 1
      fi
      download "$settings_url" downloaded-settings.json
      jq -e 'type == "object" and ([.kindVersion, .helmVersion, .kubernetesVersion, .clusterInstallerUrl, .arcOnboardingUrl] |
        all(type == "string" and length > 0))' downloaded-settings.json > /dev/null
      # Deployment values override any matching keys in the downloaded settings.
      jq -s '.[0] + .[1] | del(.settingsUrl)' downloaded-settings.json "$deployment_settings" > merged-settings.json
      settings=/etc/arc-k8s-demo.json
      install -o root -g root -m 0644 merged-settings.json "$settings"
      kind_version=$(jq -er '.kindVersion' "$settings")
      helm_version=$(jq -er '.helmVersion' "$settings")
      kubernetes_version=$(jq -er '.kubernetesVersion' "$settings")

      cluster_installer_url=$(jq -er '.clusterInstallerUrl' "$settings")
      arc_onboarding_url=$(jq -er '.arcOnboardingUrl' "$settings")
      download "$cluster_installer_url" install-kind-cluster.sh
      download "$arc_onboarding_url" onboard-k8s-to-arc.sh
      bash -n install-kind-cluster.sh
      bash -n onboard-k8s-to-arc.sh
      install -o root -g root -m 0755 install-kind-cluster.sh /usr/local/bin/install-kind-cluster.sh
      install -o root -g root -m 0755 onboard-k8s-to-arc.sh /usr/local/bin/onboard-k8s-to-arc.sh

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
      as_admin helm version --short
      as_admin az version

      for extension_name in connectedk8s k8s-extension; do
        echo "Installing Azure CLI extension: $extension_name"
        as_admin az extension add --name "$extension_name" --upgrade --yes
        as_admin az extension show --name "$extension_name" --query '{name:name, version:version}' --output json
      done

      for ((attempt=1; attempt<=30; attempt++)); do
        echo "Managed identity login and subscription selection: attempt $attempt/30"
        if as_admin az login --identity --client-id "$identity_client_id" --output none &&
           as_admin az account set --subscription "$subscription_id"; then
          break
        fi
        if (( attempt == 30 )); then
          echo "Unable to log in and select subscription $subscription_id after 30 attempts. Verify identity access and review the Azure CLI errors above." >&2
          exit 1
        fi
        echo "Login or subscription selection failed; retrying in 20 seconds."
        sleep 20
      done
      as_admin az account show --query '{subscriptionId:id, subscriptionName:name}' --output json

      install -d -m 0755 /var/lib/arc-k8s-demo
      touch /var/lib/arc-k8s-demo/ready
      echo "Bootstrap completed. Log in as $admin_user and run: onboard-k8s-to-arc"
runcmd:
  - [bash, /usr/local/sbin/arc-k8s-demo-bootstrap]
'''

var cloudInit = replace(cloudInitTemplate, '__DEPLOYMENT_SETTINGS__', base64(string(deploymentSettings)))

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${vmName}-mi'
  location: location
  tags: commonTags
}

var managedIdentityRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '34e09817-6cbe-4d01-b1a2-e0eac5743d41')

resource managedIdentityRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, managedIdentityRoleDefinitionId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: managedIdentityRoleDefinitionId
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${vmName}-nsg'
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromConfiguredSource'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${vmName}-vnet'
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.61.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'lab'
        properties: {
          addressPrefix: '10.61.1.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${vmName}-pip'
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  tags: commonTags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: virtualNetwork.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: commonTags
  // RBAC propagation can lag behind successful role assignment creation.
  dependsOn: [
    managedIdentityRoleAssignment
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        diskSizeGB: 64
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

@description('Public IP used for SSH; the kind API remains accessible only from inside the VM.')
output publicIpAddress string = publicIp.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
output vmResourceId string = vm.id
output managedIdentityResourceId string = managedIdentity.id
output managedIdentityClientId string = managedIdentity.properties.clientId
output managedIdentityPrincipalId string = managedIdentity.properties.principalId

@description('Role assignment at resource-group scope, created before the VM. The deployer needs Microsoft.Authorization/roleAssignments/write permission.')
output managedIdentityRoleAssignmentResourceId string = managedIdentityRoleAssignment.id
