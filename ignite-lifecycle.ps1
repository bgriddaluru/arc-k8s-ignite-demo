    $ErrorActionPreference = 'Stop'

    $VmResourceGroupName = 'LAB724-ArcK8s'
    $ExtensionName = 'OnboardK8sToArc'

    try {
        $targetVMs = Get-AzVM -ResourceGroupName $VmResourceGroupName

        if (-not $targetVMs) {
            throw "No VMs were found in resource group '$VmResourceGroupName'."
        }

        foreach ($vm in $targetVMs) {

            $osType = $vm.StorageProfile.OsDisk.OsType.ToString()

            # Only run this on Linux VMs
            if ($osType -ne 'Linux') {
                Write-Host "Skipping non-Linux VM '$($vm.Name)'."
                continue
            }

            Write-Host "Executing Kubernetes Arc onboarding on Linux VM '$($vm.Name)'."

            $adminUsername = $vm.OSProfile.AdminUsername
            if ([string]::IsNullOrWhiteSpace($adminUsername)) {
                throw "Cannot determine the administrator username for VM '$($vm.Name)'."
            }

            $protectedSettings = @{
                commandToExecute = "timeout 1800 cloud-init status --wait && runuser -l '$adminUsername' -c 'export KIND_EXPERIMENTAL_PROVIDER=docker; /usr/local/bin/install-kind-cluster.sh && /usr/local/bin/onboard-k8s-to-arc.sh'"
            }

            Set-AzVMExtension `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name `
                -Name $ExtensionName `
                -Publisher 'Microsoft.Azure.Extensions' `
                -ExtensionType 'CustomScript' `
                -TypeHandlerVersion '2.1' `
                -ProtectedSettings $protectedSettings `
                -Location $vm.Location `
                -ForceRerun ([Guid]::NewGuid().ToString()) |
                Out-Null

            Write-Host "Kubernetes Arc onboarding completed on VM '$($vm.Name)'."
        }
    }
    catch {
        Write-Error "Kubernetes Arc onboarding failed: $($_.Exception.Message)"
        throw
    }