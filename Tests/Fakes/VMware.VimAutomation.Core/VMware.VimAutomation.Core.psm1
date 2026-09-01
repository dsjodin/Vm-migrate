<#
    Test double for the core PowerCLI cmdlets used by BulkVMotion.

    Inventory:
      source vCenter 'vc-old' : cluster CL-OLD-01, host esx-old-01
        vm-app-01     NIC on PG-OLD-Prod-100 (VLAN 100)   -> migrates cleanly
        vm-app-02     NIC on PG-OLD-Test-200 (VLAN 200)   -> migrates cleanly
        vm-dmz-01     NIC on PG-OLD-DMZ-999  (VLAN 999)   -> no target port group, plan fails
        vm-fail-task  NIC on PG-OLD-Prod-100              -> the vCenter task fails
      target vCenter 'vc-new' : cluster CL-NEW-01, hosts esx-new-01/02, datastore DS-NEW-01

    Every Move-VM call is appended to the file named by $env:BVM_FAKE_LOG so a test can
    assert which VMs were actually migrated.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double: the parameters exist so the signatures match the real PowerCLI cmdlets, even when this stub ignores them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'Test double: -Confirm is declared to match the real PowerCLI cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test double: no state is changed.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '', Justification = 'Test double: the credential is never used.')]
param()

class VirtualEthernetCardDistributedVirtualPortBackingInfo { $Port }

$script:Tasks = @{}
$script:TaskCounter = 0

function script:New-Adapter {
    param([string]$Name, [string]$NetworkName, [string]$PortgroupKey)

    $backing = [VirtualEthernetCardDistributedVirtualPortBackingInfo]::new()
    $backing.Port = [pscustomobject]@{ PortgroupKey = $PortgroupKey }

    [pscustomobject]@{
        Name          = $Name
        NetworkName   = $NetworkName
        ExtensionData = [pscustomobject]@{ Backing = $backing }
    }
}

$script:SourceHost = [pscustomobject]@{ Name = 'esx-old-01.corp.local' }

$script:VMs = @{
    'vm-app-01'    = @{ Adapters = @((script:New-Adapter -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')); UsedSpaceGB = 40 }
    'vm-app-02'    = @{ Adapters = @((script:New-Adapter -Name 'Network adapter 1' -NetworkName 'PG-OLD-Test-200' -PortgroupKey 'dvpg-old-200')); UsedSpaceGB = 60 }
    'vm-dmz-01'    = @{ Adapters = @((script:New-Adapter -Name 'Network adapter 1' -NetworkName 'PG-OLD-DMZ-999'  -PortgroupKey 'dvpg-old-999')); UsedSpaceGB = 20 }
    'vm-fail-task' = @{ Adapters = @((script:New-Adapter -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')); UsedSpaceGB = 10 }
    'vm-huge-01'   = @{ Adapters = @((script:New-Adapter -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')); UsedSpaceGB = 9000 }
}

function script:Write-FakeLog {
    param([string]$Line)
    if ($env:BVM_FAKE_LOG) { Add-Content -LiteralPath $env:BVM_FAKE_LOG -Value $Line }
}

function Connect-VIServer {
    [CmdletBinding()]
    param([string]$Server, [System.Management.Automation.PSCredential]$Credential)
    return [pscustomobject]@{ Name = $Server; Version = '8.0.3' }
}

function Disconnect-VIServer {
    [CmdletBinding()]
    param($Server, [switch]$Confirm)
}

function Set-PowerCLIConfiguration {
    [CmdletBinding()]
    param([string]$Scope, [switch]$Confirm, [string]$DefaultVIServerMode, [string]$InvalidCertificateAction)
}

function Get-VM {
    [CmdletBinding()]
    param([string]$Name, $Server)

    if (-not $script:VMs.ContainsKey($Name)) { return @() }

    return [pscustomobject]@{
        Name          = $Name
        PowerState    = 'PoweredOn'
        UsedSpaceGB   = $script:VMs[$Name].UsedSpaceGB
        VMHost        = $script:SourceHost
        ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ Question = $null } }
    }
}

function Get-NetworkAdapter {
    [CmdletBinding()]
    param($VM, $Server)
    return $script:VMs[$VM.Name].Adapters
}

function Get-VirtualPortGroup {
    [CmdletBinding()]
    param($VMHost, [string]$Name, $Server, [switch]$Standard)
    return @()
}

function Get-Cluster {
    [CmdletBinding()]
    param([string]$Name, $VMHost, $Server)

    if ($VMHost) { return [pscustomobject]@{ Name = 'CL-OLD-01' } }
    if ($Name -eq 'CL-NEW-01') { return [pscustomobject]@{ Name = 'CL-NEW-01' } }
    return $null
}

function Get-VMHost {
    [CmdletBinding()]
    param([string]$Name, $Location, $Server)

    $hosts = @(
        [pscustomobject]@{ Name = 'esx-new-01.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 300 }
        [pscustomobject]@{ Name = 'esx-new-02.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 100 }
    )
    if ($Name) { return @($hosts | Where-Object { $_.Name -eq $Name }) }
    return $hosts
}

function Get-DatastoreCluster {
    [CmdletBinding()]
    param([string]$Name, $Server)
    return $null
}

function Get-Datastore {
    [CmdletBinding()]
    param([string]$Name, $Server)

    if ($Name -eq 'DS-NEW-01') { return [pscustomobject]@{ Name = 'DS-NEW-01'; FreeSpaceGB = 5000 } }
    return @()
}

function Get-Folder {
    [CmdletBinding()]
    param([string]$Name, [string]$Type, $Server)
    return @()
}

function Move-VM {
    [CmdletBinding()]
    param(
        $VM, $Destination, $NetworkAdapter, $PortGroup, $Datastore, $InventoryLocation,
        [string]$VMotionPriority, [string]$DiskStorageFormat, [switch]$RunAsync, [switch]$Confirm
    )

    if ($VM.Name -eq 'vm-fail-start') { throw 'Simulated failure while starting the migration.' }

    script:Write-FakeLog -Line ('MOVE {0} -> host={1} datastore={2} portgroups={3}' -f `
            $VM.Name, $Destination.Name, $(if ($Datastore) { $Datastore.Name } else { 'none' }), (($PortGroup | ForEach-Object { $_.Name }) -join '+'))

    $script:TaskCounter++
    $id = 'Task-task-{0}' -f $script:TaskCounter

    # The task reports Running once and reaches its end state on the next poll.
    $script:Tasks[$id] = [pscustomobject]@{
        Id              = $id
        State           = 'Running'
        PercentComplete = 10
        VMName          = $VM.Name
        PollCount       = 0
        ExtensionData   = [pscustomobject]@{ Info = [pscustomobject]@{ Error = $null } }
    }
    return $script:Tasks[$id]
}

function Get-Task {
    [CmdletBinding()]
    param([string]$Id, $Server)

    if (-not $script:Tasks.ContainsKey($Id)) { return $null }

    $task = $script:Tasks[$Id]
    $task.PollCount++

    if ($task.PollCount -ge 1) {
        if ($task.VMName -eq 'vm-fail-task') {
            $task.State = 'Error'
            $task.ExtensionData.Info.Error = [pscustomobject]@{ LocalizedMessage = 'Simulated vMotion failure: the destination host is not compatible.' }
        }
        else {
            $task.State = 'Success'
            $task.PercentComplete = 100
        }
    }
    return $task
}

Export-ModuleMember -Function 'Connect-VIServer', 'Disconnect-VIServer', 'Set-PowerCLIConfiguration',
'Get-VM', 'Get-NetworkAdapter', 'Get-VirtualPortGroup', 'Get-Cluster', 'Get-VMHost',
'Get-Datastore', 'Get-DatastoreCluster', 'Get-Folder', 'Move-VM', 'Get-Task'
