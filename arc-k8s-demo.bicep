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
  - path: /usr/local/sbin/arc-k8s-demo-bootstrap
    owner: root:root
    permissions: '0750'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      umask 022

      deployment_settings=/etc/arc-k8s-demo-deployment.json
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
      jq -e 'type == "object"' downloaded-settings.json > /dev/null
      # Deployment values override any matching keys in the downloaded settings.
      jq -s '.[0] + .[1] | del(.settingsUrl)' downloaded-settings.json "$deployment_settings" > merged-settings.json
      settings=/etc/arc-k8s-demo.json
      install -o root -g root -m 0644 merged-settings.json "$settings"

      tools_installer_url=$(jq -er '.toolsInstallerUrl' "$settings")
      cluster_installer_url=$(jq -er '.clusterInstallerUrl' "$settings")
      arc_onboarding_url=$(jq -er '.arcOnboardingUrl' "$settings")
      download "$tools_installer_url" install-tools.sh
      download "$cluster_installer_url" install-kind-cluster.sh
      download "$arc_onboarding_url" onboard-k8s-to-arc.sh
      bash -n install-tools.sh
      bash -n install-kind-cluster.sh
      bash -n onboard-k8s-to-arc.sh
      install -o root -g root -m 0750 install-tools.sh /usr/local/sbin/install-tools.sh
      install -o root -g root -m 0755 install-kind-cluster.sh /usr/local/bin/install-kind-cluster.sh
      install -o root -g root -m 0755 onboard-k8s-to-arc.sh /usr/local/bin/onboard-k8s-to-arc.sh

      /usr/local/sbin/install-tools.sh
      echo "VM preparation completed. Run install-kind-cluster.sh, then onboard-k8s-to-arc.sh as the configured administrator, without sudo."
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
