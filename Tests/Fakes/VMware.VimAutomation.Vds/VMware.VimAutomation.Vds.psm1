<#
    Test double for the distributed switch part of PowerCLI.

    It serves a small fixed inventory: the source vCenter has three port groups on
    the old VDS, the target vCenter has two usable port groups plus an uplink group
    on 'VDS-NEW'. Only what BulkVMotion actually reads is implemented.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double: the parameters exist so the signatures match the real PowerCLI cmdlets, even when this stub ignores them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'Test double: -Confirm is declared to match the real PowerCLI cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test double: no state is changed.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '', Justification = 'Test double: the credential is never used.')]
param()

class VmwareDistributedVirtualSwitchVlanIdSpec { [int]$VlanId }
class VmwareDistributedVirtualSwitchTrunkVlanSpec { $VlanId }
class NumericRange { [int]$Start; [int]$End }

function script:New-Spec {
    param([int]$VlanId)
    $spec = [VmwareDistributedVirtualSwitchVlanIdSpec]::new()
    $spec.VlanId = $VlanId
    return $spec
}

function script:New-Pg {
    param([string]$Name, [string]$Key, [int]$VlanId, [bool]$IsUplink = $false, [string]$Switch = 'VDS-NEW')
    [pscustomobject]@{
        Name          = $Name
        Key           = $Key
        IsUplink      = $IsUplink
        VDSwitch      = $Switch
        ExtensionData = [pscustomobject]@{
            Key    = $Key
            Config = [pscustomobject]@{
                DefaultPortConfig = [pscustomobject]@{ Vlan = (script:New-Spec -VlanId $VlanId) }
            }
        }
    }
}

$script:SourcePortGroups = @(
    script:New-Pg -Name 'PG-OLD-Prod-100' -Key 'dvpg-old-100' -VlanId 100 -Switch 'VDS-OLD'
    script:New-Pg -Name 'PG-OLD-Test-200' -Key 'dvpg-old-200' -VlanId 200 -Switch 'VDS-OLD'
    script:New-Pg -Name 'PG-OLD-DMZ-999'  -Key 'dvpg-old-999' -VlanId 999 -Switch 'VDS-OLD'
)

$script:TargetPortGroups = @(
    script:New-Pg -Name 'PG-NEW-Prod-100' -Key 'dvpg-new-100' -VlanId 100
    script:New-Pg -Name 'PG-NEW-Test-200' -Key 'dvpg-new-200' -VlanId 200
    script:New-Pg -Name 'VDS-NEW-Uplinks' -Key 'dvpg-new-upl' -VlanId 0 -IsUplink $true
)

function Get-VDSwitch {
    [CmdletBinding()]
    param([string]$Name, $Server)

    if ($Name -eq 'VDS-NEW') { return [pscustomobject]@{ Name = 'VDS-NEW' } }
    return $null
}

function Get-VDPortgroup {
    [CmdletBinding()]
    param($VDSwitch, $Server, [string]$Name)

    # Asking for one switch returns that switch's port groups. Asking without a switch
    # is the source side cache, which in a single vCenter legitimately sees both the old
    # and the new VDS - that is exactly why -TargetVDSwitch matters.
    $result = if ($VDSwitch) {
        @($script:SourcePortGroups + $script:TargetPortGroups | Where-Object { $_.VDSwitch -eq $VDSwitch.Name })
    }
    else {
        @($script:SourcePortGroups + $script:TargetPortGroups)
    }

    if ($Name) { $result = @($result | Where-Object { $_.Name -eq $Name }) }
    return $result
}

Export-ModuleMember -Function 'Get-VDSwitch', 'Get-VDPortgroup'
