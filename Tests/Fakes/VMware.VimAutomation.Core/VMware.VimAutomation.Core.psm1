<#
    Test double for the core PowerCLI cmdlets used by BulkVMotion.

    The inventory models the real three phase journey:

      vc-old  CL-OLD-01   esx-old-01                sees DS-OLD-01
              CL-NEW-01   esx-new-01, esx-new-02    sees DS-OLD-01 + DS-NEW-01
              CL-NOSAN    esx-iso-01                sees DS-ISOLATED only
      vc-new  CL-FINAL-01 esx-vc2-01, esx-vc2-02    sees DS-NEW-01 (the same shared LUN)

    Phase 1 moves a VM from CL-OLD-01 to CL-NEW-01 while it keeps DS-OLD-01, which is
    why the new cluster has to see that datastore. Phase 2 moves it to DS-NEW-01.
    Phase 3 moves it to vc-new/CL-FINAL-01 with DS-NEW-01 unchanged.

    Every Move-VM and Set-NetworkAdapter call is appended to $env:BVM_FAKE_LOG so a test
    can assert what was actually done.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test double: the parameters exist so the signatures match the real PowerCLI cmdlets, even when this stub ignores them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'Test double: -Confirm is declared to match the real PowerCLI cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test double: no state is changed.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '', Justification = 'Test double: the credential is never used.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test double: the helper returns a collection of tasks.')]
param()

class VirtualEthernetCardDistributedVirtualPortBackingInfo { $Port }

$script:Tasks = @{}
$script:TaskCounter = 0

function script:New-Adapter {
    param([string]$Name, [string]$NetworkName, [string]$PortgroupKey, [string]$VMName)

    $backing = [VirtualEthernetCardDistributedVirtualPortBackingInfo]::new()
    $backing.Port = [pscustomobject]@{ PortgroupKey = $PortgroupKey }

    [pscustomobject]@{
        Name          = $Name
        NetworkName   = $NetworkName
        Parent        = $VMName
        ExtensionData = [pscustomobject]@{ Backing = $backing }
    }
}

# Which datastores each host can see.
$script:HostDatastores = @{
    'esx-old-01.corp.local' = @('DS-OLD-01')
    'esx-new-01.corp.local' = @('DS-OLD-01', 'DS-NEW-01')
    'esx-new-02.corp.local' = @('DS-OLD-01', 'DS-NEW-01')
    'esx-vc2-01.corp.local' = @('DS-NEW-01')
    'esx-vc2-02.corp.local' = @('DS-NEW-01')
    'esx-iso-01.corp.local' = @('DS-ISOLATED')
}

$script:HostCluster = @{
    'esx-old-01.corp.local' = 'CL-OLD-01'
    'esx-new-01.corp.local' = 'CL-NEW-01'
    'esx-new-02.corp.local' = 'CL-NEW-01'
    'esx-vc2-01.corp.local' = 'CL-FINAL-01'
    'esx-vc2-02.corp.local' = 'CL-FINAL-01'
    'esx-iso-01.corp.local' = 'CL-NOSAN'
}

$script:Hosts = @(
    [pscustomobject]@{ Name = 'esx-old-01.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 400 }
    [pscustomobject]@{ Name = 'esx-new-01.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 300 }
    [pscustomobject]@{ Name = 'esx-new-02.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 100 }
    [pscustomobject]@{ Name = 'esx-vc2-01.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 100 }
    [pscustomobject]@{ Name = 'esx-vc2-02.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 200 }
    [pscustomobject]@{ Name = 'esx-iso-01.corp.local'; ConnectionState = 'Connected'; PowerState = 'PoweredOn'; MemoryTotalGB = 512; MemoryUsageGB = 100 }
)

$script:Datastores = @{
    'DS-OLD-01'   = 5000
    'DS-NEW-01'   = 5000
    'DS-ISOLATED' = 5000
    'DS-TINY-01'  = 5
}

# The second vCenter only has the shared volume presented to it. A VM that has not had
# its phase 2 storage move cannot be found a datastore there, which is exactly the check
# phase 3 relies on.
$script:DatastoresByVIServer = @{
    'vc-old.corp.local' = @('DS-OLD-01', 'DS-NEW-01', 'DS-ISOLATED', 'DS-TINY-01')
    'vc-new.corp.local' = @('DS-NEW-01')
}

$script:VMs = @{
    # Phase 1 candidates: old cluster, old storage, old VDS.
    'vm-app-01'     = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 40
        Adapters = @((script:New-Adapter -VMName 'vm-app-01' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')) }
    'vm-app-02'     = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 60
        Adapters = @((script:New-Adapter -VMName 'vm-app-02' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Test-200' -PortgroupKey 'dvpg-old-200')) }
    'vm-dmz-01'     = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 20
        Adapters = @((script:New-Adapter -VMName 'vm-dmz-01' -Name 'Network adapter 1' -NetworkName 'PG-OLD-DMZ-999' -PortgroupKey 'dvpg-old-999')) }
    'vm-fail-task'  = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 10
        Adapters = @((script:New-Adapter -VMName 'vm-fail-task' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')) }
    'vm-huge-01'    = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 9000
        Adapters = @((script:New-Adapter -VMName 'vm-huge-01' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')) }

    # Phase 1 done: new cluster and new VDS, still on the old storage.
    'vm-phase1-01'  = @{ Host = 'esx-new-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-phase1-01' -Name 'Network adapter 1' -NetworkName 'PG-NEW-Prod-100' -PortgroupKey 'dvpg-new-100')) }

    # Three more on the same host, so a phase 2 wave has to queue behind the 2 per host
    # Storage vMotion limit.
    'vm-phase1-02'  = @{ Host = 'esx-new-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-phase1-02' -Name 'Network adapter 1' -NetworkName 'PG-NEW-Prod-100' -PortgroupKey 'dvpg-new-100')) }
    'vm-phase1-03'  = @{ Host = 'esx-new-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-phase1-03' -Name 'Network adapter 1' -NetworkName 'PG-NEW-Prod-100' -PortgroupKey 'dvpg-new-100')) }
    'vm-phase1-04'  = @{ Host = 'esx-new-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-phase1-04' -Name 'Network adapter 1' -NetworkName 'PG-NEW-Prod-100' -PortgroupKey 'dvpg-new-100')) }

    # Phase 2 done: new cluster, new VDS, new storage - ready for the cross vCenter move.
    'vm-phase2-01'  = @{ Host = 'esx-new-01.corp.local'; Datastore = 'DS-NEW-01'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-phase2-01' -Name 'Network adapter 1' -NetworkName 'PG-NEW-Prod-100' -PortgroupKey 'dvpg-new-100')) }

    # In the new cluster but still on the old VDS port group.
    'vm-netonly-01' = @{ Host = 'esx-new-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-netonly-01' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')) }

    # Two NICs on different VLANs - each has to land on its own port group.
    'vm-multinic-01' = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 50
        Adapters = @(
            (script:New-Adapter -VMName 'vm-multinic-01' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')
            (script:New-Adapter -VMName 'vm-multinic-01' -Name 'Network adapter 2' -NetworkName 'PG-OLD-Bkp-300' -PortgroupKey 'dvpg-old-300')
        ) }

    # Same again, for the wave that sends VMs to two different switches.
    'vm-multinic-02' = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-OLD-01'; UsedSpaceGB = 50
        Adapters = @(
            (script:New-Adapter -VMName 'vm-multinic-02' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')
            (script:New-Adapter -VMName 'vm-multinic-02' -Name 'Network adapter 2' -NetworkName 'PG-OLD-Bkp-300' -PortgroupKey 'dvpg-old-300')
        ) }

    # On storage the new cluster cannot see - phase 1 must refuse this one.
    'vm-nosan-01'   = @{ Host = 'esx-old-01.corp.local'; Datastore = 'DS-ISOLATED'; UsedSpaceGB = 30
        Adapters = @((script:New-Adapter -VMName 'vm-nosan-01' -Name 'Network adapter 1' -NetworkName 'PG-OLD-Prod-100' -PortgroupKey 'dvpg-old-100')) }
}

#region Inventory state that survives between runs --------------------------------

# Each phase runs as its own process, so the effect of a migration is written to
# $env:BVM_FAKE_STATE. Without that the three phase journey could not be tested: phase 3
# would still see the VM where it was before phase 1.

function script:Restore-FakeState {
    if (-not $env:BVM_FAKE_STATE -or -not (Test-Path -LiteralPath $env:BVM_FAKE_STATE)) { return }

    $saved = Get-Content -LiteralPath $env:BVM_FAKE_STATE -Raw | ConvertFrom-Json
    foreach ($entry in $saved.PSObject.Properties) {
        $name = $entry.Name
        if (-not $script:VMs.ContainsKey($name)) { continue }

        $script:VMs[$name].Host      = $entry.Value.Host
        $script:VMs[$name].Datastore = $entry.Value.Datastore

        foreach ($savedAdapter in @($entry.Value.Adapters)) {
            $adapter = $script:VMs[$name].Adapters | Where-Object { $_.Name -eq $savedAdapter.Name } | Select-Object -First 1
            if (-not $adapter) { continue }
            $adapter.NetworkName = $savedAdapter.NetworkName
            $adapter.ExtensionData.Backing.Port.PortgroupKey = $savedAdapter.PortgroupKey
        }
    }
}

function script:Save-FakeState {
    if (-not $env:BVM_FAKE_STATE) { return }

    $state = [ordered]@{}
    foreach ($name in ($script:VMs.Keys | Sort-Object)) {
        $state[$name] = [ordered]@{
            Host      = $script:VMs[$name].Host
            Datastore = $script:VMs[$name].Datastore
            Adapters  = @($script:VMs[$name].Adapters | ForEach-Object {
                    [ordered]@{
                        Name         = $_.Name
                        NetworkName  = $_.NetworkName
                        PortgroupKey = $_.ExtensionData.Backing.Port.PortgroupKey
                    }
                })
        }
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $env:BVM_FAKE_STATE
}

script:Restore-FakeState

#endregion Inventory state that survives between runs

function script:Write-FakeLog {
    param([string]$Line)
    if ($env:BVM_FAKE_LOG) { Add-Content -LiteralPath $env:BVM_FAKE_LOG -Value $Line }
}

# Migrations other engineers have started, seeded by $env:BVM_EXTERNAL_TASKS as
# "<vmname>=<migrate|relocate>" entries separated by semicolons.
function script:Get-ExternalTasks {
    if (-not $env:BVM_EXTERNAL_TASKS) { return @() }

    $result = @()
    foreach ($entry in ($env:BVM_EXTERNAL_TASKS -split ';')) {
        $part = $entry.Trim()
        if (-not $part) { continue }
        $split = $part.Split('=')
        $vmName = $split[0].Trim()
        $kind = if ($split.Count -gt 1) { $split[1].Trim() } else { 'migrate' }
        $result += [pscustomobject]@{
            Id            = "Task-external-$vmName"
            State         = 'Running'
            ExtensionData = [pscustomobject]@{
                Info = [pscustomobject]@{
                    DescriptionId = "VirtualMachine.$kind"
                    Entity        = $vmName
                }
            }
        }
    }
    return $result
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
    param([string]$Name, $Id, $Server)

    # A task entity resolves back to a VM.
    if ($Id) { $Name = [string]$Id }
    if (-not $Name -or -not $script:VMs.ContainsKey($Name)) { return @() }

    return [pscustomobject]@{
        Name          = $Name
        PowerState    = 'PoweredOn'
        UsedSpaceGB   = $script:VMs[$Name].UsedSpaceGB
        VMHost        = [pscustomobject]@{ Name = $script:VMs[$Name].Host }
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

    if ($VMHost) { return [pscustomobject]@{ Name = $script:HostCluster[$VMHost.Name] } }
    if ($Name -and ($script:HostCluster.Values -contains $Name)) { return [pscustomobject]@{ Name = $Name } }
    return $null
}

function Get-VMHost {
    [CmdletBinding()]
    param([string]$Name, $Location, $Server)

    if ($Name) { return @($script:Hosts | Where-Object { $_.Name -eq $Name }) }
    if ($Location) { return @($script:Hosts | Where-Object { $script:HostCluster[$_.Name] -eq $Location.Name }) }
    return $script:Hosts
}

function Get-DatastoreCluster {
    [CmdletBinding()]
    param([string]$Name, $Server)
    return $null
}

function Get-Datastore {
    [CmdletBinding()]
    param([string]$Name, $VM, $VMHost, $Location, $Server)

    # Which datastores is this VM on today?
    if ($VM) { return [pscustomobject]@{ Name = $script:VMs[$VM.Name].Datastore; FreeSpaceGB = 5000 } }

    # Which datastores can this host see?
    if ($VMHost) {
        return @($script:HostDatastores[$VMHost.Name] | ForEach-Object {
                [pscustomobject]@{ Name = $_; FreeSpaceGB = $script:Datastores[$_] }
            })
    }

    # Members of a datastore cluster - there are none in this inventory.
    if ($Location) { return @() }

    if ($Name -and $script:Datastores.ContainsKey($Name)) {
        $viServer = if ($Server) { [string]$Server.Name } else { 'vc-old.corp.local' }
        $available = if ($script:DatastoresByVIServer.ContainsKey($viServer)) { $script:DatastoresByVIServer[$viServer] } else { @() }
        if ($Name -in $available) {
            return [pscustomobject]@{ Name = $Name; FreeSpaceGB = $script:Datastores[$Name] }
        }
    }
    return @()
}

function Get-Folder {
    [CmdletBinding()]
    param([string]$Name, [string]$Type, $Server)
    return @()
}

function Set-NetworkAdapter {
    [CmdletBinding()]
    param($NetworkAdapter, $Portgroup, [switch]$Confirm)

    script:Write-FakeLog -Line ('SETNIC {0} {1} -> {2}' -f $NetworkAdapter.Parent, $NetworkAdapter.Name, $Portgroup.Name)

    $adapter = $script:VMs[$NetworkAdapter.Parent].Adapters | Where-Object { $_.Name -eq $NetworkAdapter.Name } | Select-Object -First 1
    if ($adapter) {
        $adapter.NetworkName = $Portgroup.Name
        $adapter.ExtensionData.Backing.Port.PortgroupKey = $Portgroup.Key
    }
    script:Save-FakeState
}

function Move-VM {
    [CmdletBinding()]
    param(
        $VM, $Destination, $NetworkAdapter, $PortGroup, $Datastore, $InventoryLocation,
        [string]$VMotionPriority, [string]$DiskStorageFormat, [switch]$RunAsync, [switch]$Confirm
    )

    if ($VM.Name -eq 'vm-fail-start') { throw 'Simulated failure while starting the migration.' }

    script:Write-FakeLog -Line ('MOVE {0} -> host={1} datastore={2} portgroups={3}' -f `
            $VM.Name,
        $(if ($Destination) { $Destination.Name } else { 'none' }),
        $(if ($Datastore) { $Datastore.Name } else { 'none' }),
        $(if ($PortGroup) { (($PortGroup | ForEach-Object { $_.Name }) -join '+') } else { 'none' }))

    # The host and operation are recorded on start and on finish, so a test can work out
    # the highest concurrency that was ever reached on any one host.
    $operation = if ($Datastore -and -not $Destination) { 'svmotion' }
    elseif ($Datastore -and $Destination -and $Datastore.Name -ne $script:VMs[$VM.Name].Datastore) { 'svmotion' }
    else { 'vmotion' }
    $costHost = if ($Destination) { $Destination.Name } else { $script:VMs[$VM.Name].Host }
    script:Write-FakeLog -Line ('START {0} {1} {2}' -f $VM.Name, $costHost, $operation)

    # Apply the migration to the inventory, so the next phase sees where the VM ended up.
    if ($Destination) { $script:VMs[$VM.Name].Host = $Destination.Name }
    if ($Datastore) { $script:VMs[$VM.Name].Datastore = $Datastore.Name }
    if ($PortGroup) {
        $targets = @($PortGroup)
        for ($i = 0; $i -lt $targets.Count -and $i -lt $script:VMs[$VM.Name].Adapters.Count; $i++) {
            $script:VMs[$VM.Name].Adapters[$i].NetworkName = $targets[$i].Name
            $script:VMs[$VM.Name].Adapters[$i].ExtensionData.Backing.Port.PortgroupKey = $targets[$i].Key
        }
    }
    script:Save-FakeState

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
    param([string]$Id, [string]$Status, $Server)

    if (-not $Id -and $Status -eq 'Running') {
        return @(script:Get-ExternalTasks) + @($script:Tasks.Values | Where-Object { $_.State -eq 'Running' })
    }

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
        script:Write-FakeLog -Line ('END {0}' -f $task.VMName)
    }
    return $task
}

Export-ModuleMember -Function 'Connect-VIServer', 'Disconnect-VIServer', 'Set-PowerCLIConfiguration',
'Get-VM', 'Get-NetworkAdapter', 'Get-VirtualPortGroup', 'Get-Cluster', 'Get-VMHost',
'Get-Datastore', 'Get-DatastoreCluster', 'Get-Folder', 'Move-VM', 'Get-Task', 'Set-NetworkAdapter'
