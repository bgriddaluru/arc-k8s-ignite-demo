$ErrorActionPreference = 'Stop'

$ResourceGroup = 'bgriddaluru-test'
$VmName = 'arc-k8s-demo'  # Change if you supplied a different vmName

az account show --output table
if ($LASTEXITCODE -ne 0) { throw 'Check your Azure login.' }

if ((Read-Host "Type DELETE to remove '$VmName' and its related resources") -cne 'DELETE') {
    throw 'Cleanup cancelled.'
}

# Dependency order matters. NIC/disk may already be deleted with the VM.
$Resources = [ordered]@{
    'Microsoft.Compute/virtualMachines'             = $VmName
    'Microsoft.Network/networkInterfaces'           = "$VmName-nic"
    'Microsoft.Compute/disks'                       = "$VmName-osdisk"
    'Microsoft.Network/publicIPAddresses'           = "$VmName-pip"
    'Microsoft.Network/virtualNetworks'             = "$VmName-vnet"
    'Microsoft.Network/networkSecurityGroups'       = "$VmName-nsg"
    'Microsoft.ManagedIdentity/userAssignedIdentities' = "$VmName-mi"
}

foreach ($Resource in $Resources.GetEnumerator()) {
    $ResourceId = az resource list `
        --resource-group $ResourceGroup `
        --resource-type $Resource.Key `
        --query "[?name=='$($Resource.Value)'].id | [0]" `
        --output tsv

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check $($Resource.Value)."
    }

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        Write-Host "Already absent: $($Resource.Value)"
        continue
    }

    Write-Host "Deleting: $($Resource.Value)"

    if ($Resource.Key -eq 'Microsoft.Compute/virtualMachines') {
        az vm delete --ids $ResourceId --yes
    } else {
        az resource delete --ids $ResourceId
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete $($Resource.Value). Cleanup stopped."
    }
}

Write-Host 'Cleanup completed.'