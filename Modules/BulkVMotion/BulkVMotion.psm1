<#
    BulkVMotion.psm1

    Helper functions for bulk cross-cluster / cross-vCenter vMotion driven by CSV files.

    The module is deliberately split into small functions so that the pure logic
    (VLAN parsing, port group matching, CSV validation) can be unit tested without
    a live vCenter connection.
#>

#region Logging -----------------------------------------------------------------

$script:LogFile      = $null
$script:LogMinLevel  = 'Info'
$script:LogLevelRank = @{ Debug = 0; Info = 1; Success = 1; Warning = 2; Error = 3 }

function Start-BulkVMotionLog {
    <#
    .SYNOPSIS
        Opens a new log file for the current run.
    .OUTPUTS
        The full path of the log file that was created.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive operator tool: coloured progress output on the console is the point, and every line is written to the log file as well.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates the run log file; there is nothing to confirm.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$MinimumLevel = 'Info'
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName   = ($Name -replace '[^\w\.\-]', '_')
    $script:LogFile     = Join-Path $LogDirectory ('{0}_{1}.log' -f $safeName, $stamp)
    $script:LogMinLevel = $MinimumLevel

    $header = @(
        '=' * 100
        ' Bulk vMotion run started : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
        ' Log file                 : {0}' -f $script:LogFile
        ' User                     : {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
        ' Computer                 : {0}' -f $env:COMPUTERNAME
        ' PowerShell               : {0}' -f $PSVersionTable.PSVersion
        '=' * 100
    )
    $header | Out-File -FilePath $script:LogFile -Encoding utf8 -Append
    $header | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }

    return $script:LogFile
}

function Get-BulkVMotionLogFile {
    [CmdletBinding()]
    param()
    return $script:LogFile
}

function Write-BulkVMotionLog {
    <#
    .SYNOPSIS
        Writes a timestamped entry to the console and to the run log file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive operator tool: coloured progress output on the console is the point, and every line is written to the log file as well.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)][AllowEmptyString()][string]$Message,
        [ValidateSet('Debug', 'Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info',
        [string]$VMName
    )

    process {
        if ($script:LogLevelRank[$Level] -lt $script:LogLevelRank[$script:LogMinLevel]) { return }

        $prefix = if ($VMName) { '[{0}] ' -f $VMName } else { '' }
        $line   = '{0} [{1,-7}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $prefix, $Message

        $color = switch ($Level) {
            'Debug'   { 'DarkGray' }
            'Info'    { 'Gray' }
            'Success' { 'Green' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
        }
        Write-Host $line -ForegroundColor $color

        if ($script:LogFile) {
            try {
                $line | Out-File -FilePath $script:LogFile -Encoding utf8 -Append
            }
            catch {
                Write-Host "Failed to write to log file '$script:LogFile': $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

function Stop-BulkVMotionLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive operator tool: coloured progress output on the console is the point, and every line is written to the log file as well.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Closes the run log file; there is nothing to confirm.')]
    [CmdletBinding()]
    param([hashtable]$Summary)

    # Note the parentheses: without them the comma binds into the multiplication.
    $lines = @(
        ('=' * 100)
        (' Bulk vMotion run finished : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
    )
    if ($Summary) {
        foreach ($key in ($Summary.Keys | Sort-Object)) {
            $lines += ' {0,-25}: {1}' -f $key, $Summary[$key]
        }
    }
    $lines += '=' * 100

    $lines | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    if ($script:LogFile) { $lines | Out-File -FilePath $script:LogFile -Encoding utf8 -Append }

    $script:LogFile = $null
}

#endregion Logging

#region CSV handling ------------------------------------------------------------

# Only VMName is mandatory - everything else can come from the run defaults.
$script:RequiredCsvColumns = @('VMName')
$script:KnownCsvColumns    = @(
    'VMName', 'SourceCluster', 'TargetCluster', 'TargetHost', 'TargetDatastore',
    'TargetFolder', 'TargetPortGroup', 'Priority', 'Notes'
)

function Import-MigrationCsv {
    <#
    .SYNOPSIS
        Reads and validates a migration CSV file.
    .DESCRIPTION
        Returns one PSCustomObject per row with all known columns present (empty
        string when absent), so downstream code never has to test for the property.
        Throws when a mandatory column is missing or when the file has no data rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [char]$Delimiter = ','
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter)
    if ($rows.Count -eq 0) {
        throw "CSV file '$Path' contains no data rows."
    }

    $columns = @($rows[0].PSObject.Properties.Name)
    $missing = @($script:RequiredCsvColumns | Where-Object { $_ -notin $columns })
    if ($missing.Count -gt 0) {
        throw "CSV file '$Path' is missing required column(s): $($missing -join ', ')"
    }

    $unknown = @($columns | Where-Object { $_ -notin $script:KnownCsvColumns })
    if ($unknown.Count -gt 0) {
        Write-BulkVMotionLog -Level Warning -Message "CSV '$([System.IO.Path]::GetFileName($Path))' contains unrecognised column(s) that will be ignored: $($unknown -join ', ')"
    }

    $lineNumber = 1
    foreach ($row in $rows) {
        $lineNumber++
        $normalized = [ordered]@{ CsvLine = $lineNumber }
        foreach ($column in $script:KnownCsvColumns) {
            $value = if ($column -in $columns) { $row.$column } else { $null }
            $normalized[$column] = if ($null -eq $value) { '' } else { ([string]$value).Trim() }
        }

        if ([string]::IsNullOrWhiteSpace($normalized['VMName'])) {
            Write-BulkVMotionLog -Level Warning -Message "Skipping CSV line $lineNumber - VMName is empty."
            continue
        }

        [pscustomobject]$normalized
    }
}

function Move-ProcessedCsv {
    <#
    .SYNOPSIS
        Moves a fully processed CSV file from the IN folder to the MOVED folder.
    .DESCRIPTION
        A timestamp is appended to the file name so that re-runs of the same file
        never overwrite an earlier result.
    .OUTPUTS
        The destination path of the moved file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target    = Join-Path $Destination ('{0}_{1}{2}' -f $baseName, $stamp, $extension)

    # Extremely unlikely, but never clobber an existing archive file.
    $suffix = 1
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $Destination ('{0}_{1}_{2}{3}' -f $baseName, $stamp, $suffix, $extension)
        $suffix++
    }

    if ($PSCmdlet.ShouldProcess($Path, "Move to $target")) {
        Move-Item -LiteralPath $Path -Destination $target -Force
    }

    return $target
}

#endregion CSV handling

#region VLAN / port group mapping -----------------------------------------------

function Get-PortGroupVlanInfo {
    <#
    .SYNOPSIS
        Extracts the VLAN configuration from a distributed or standard port group.
    .DESCRIPTION
        Works for VDPortgroup objects (access, trunk and private VLAN specs) as well
        as classic VirtualPortGroup objects on a standard vSwitch.

        The returned 'Key' is the value used to match a source port group to a target
        port group: two port groups carrying the same VLAN produce the same key, so an
        access VLAN never matches a trunk and a PVLAN never matches a plain VLAN.
    .OUTPUTS
        PSCustomObject with Name, Type, VlanId, Key and Description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$PortGroup
    )

    process {
        $name     = [string]$PortGroup.Name
        $vlanSpec = $null

        $extensionData = $PortGroup.PSObject.Properties['ExtensionData']
        if ($extensionData -and $extensionData.Value -and $extensionData.Value.Config -and $extensionData.Value.Config.DefaultPortConfig) {
            $vlanSpec = $extensionData.Value.Config.DefaultPortConfig.Vlan
        }

        if ($vlanSpec) {
            $specType = $vlanSpec.GetType().Name
            switch -Wildcard ($specType) {

                '*TrunkVlanSpec' {
                    # VlanId is an array of NumericRange objects.
                    $ranges = @($vlanSpec.VlanId | ForEach-Object {
                            if ($_.Start -eq $_.End) { '{0}' -f $_.Start } else { '{0}-{1}' -f $_.Start, $_.End }
                        }) | Sort-Object
                    $rangeText = $ranges -join ','
                    return [pscustomobject]@{
                        Name        = $name
                        Type        = 'Trunk'
                        VlanId      = $null
                        Key         = 'TRUNK:{0}' -f $rangeText
                        Description = 'Trunk {0}' -f $rangeText
                    }
                }

                '*PvlanSpec' {
                    return [pscustomobject]@{
                        Name        = $name
                        Type        = 'PrivateVlan'
                        VlanId      = [int]$vlanSpec.PvlanId
                        Key         = 'PVLAN:{0}' -f $vlanSpec.PvlanId
                        Description = 'Private VLAN {0}' -f $vlanSpec.PvlanId
                    }
                }

                default {
                    # VmwareDistributedVirtualSwitchVlanIdSpec - a plain access VLAN.
                    $id = [int]$vlanSpec.VlanId
                    return [pscustomobject]@{
                        Name        = $name
                        Type        = if ($id -eq 0) { 'None' } else { 'Access' }
                        VlanId      = $id
                        Key         = 'VLAN:{0}' -f $id
                        Description = if ($id -eq 0) { 'No VLAN (untagged)' } else { 'VLAN {0}' -f $id }
                    }
                }
            }
        }

        # Standard vSwitch port group.
        $vlanProperty = $PortGroup.PSObject.Properties['VLanId']
        if ($vlanProperty -and $null -ne $vlanProperty.Value) {
            $id = [int]$vlanProperty.Value
            if ($id -eq 4095) {
                return [pscustomobject]@{
                    Name        = $name
                    Type        = 'Trunk'
                    VlanId      = $null
                    Key         = 'TRUNK:0-4094'
                    Description = 'Trunk 0-4094 (VGT)'
                }
            }
            return [pscustomobject]@{
                Name        = $name
                Type        = if ($id -eq 0) { 'None' } else { 'Access' }
                VlanId      = $id
                Key         = 'VLAN:{0}' -f $id
                Description = if ($id -eq 0) { 'No VLAN (untagged)' } else { 'VLAN {0}' -f $id }
            }
        }

        return [pscustomobject]@{
            Name        = $name
            Type        = 'Unknown'
            VlanId      = $null
            Key         = $null
            Description = 'VLAN configuration could not be determined'
        }
    }
}

function Get-VlanPortGroupMap {
    <#
    .SYNOPSIS
        Builds a VLAN -> target port group lookup table from one or more target VDS.
    .DESCRIPTION
        Uplink port groups are excluded. Port groups whose VLAN cannot be determined
        are reported and left out of the map. When two port groups on the target side
        carry the same VLAN the ambiguity is recorded, so that Resolve-TargetPortGroup
        can fail loudly instead of guessing.
    .OUTPUTS
        Hashtable keyed by VLAN key; each value is an array of port group objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$PortGroup
    )

    $map = @{}

    foreach ($pg in $PortGroup) {
        $isUplink = $pg.PSObject.Properties['IsUplink']
        if ($isUplink -and $isUplink.Value) {
            Write-BulkVMotionLog -Level Debug -Message "Ignoring uplink port group '$($pg.Name)'."
            continue
        }

        $vlanInfo = Get-PortGroupVlanInfo -PortGroup $pg
        if (-not $vlanInfo.Key) {
            Write-BulkVMotionLog -Level Warning -Message "Target port group '$($pg.Name)' has no readable VLAN configuration and is excluded from the mapping table."
            continue
        }

        if (-not $map.ContainsKey($vlanInfo.Key)) { $map[$vlanInfo.Key] = @() }
        $map[$vlanInfo.Key] += [pscustomobject]@{
            PortGroup = $pg
            Name      = $pg.Name
            VlanInfo  = $vlanInfo
        }
    }

    return $map
}

function Write-VlanPortGroupMapReport {
    <#
    .SYNOPSIS
        Logs the resolved VLAN mapping table so every run documents what it will do.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Map)

    Write-BulkVMotionLog -Message ('Target port group VLAN table ({0} VLAN(s)):' -f $Map.Keys.Count)
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $names = @($Map[$key] | ForEach-Object { $_.Name })
        $level = if ($names.Count -gt 1) { 'Warning' } else { 'Info' }
        $note  = if ($names.Count -gt 1) { ' <-- ambiguous, needs TargetPortGroup in the CSV' } else { '' }
        Write-BulkVMotionLog -Level $level -Message ('  {0,-16} -> {1}{2}' -f $key, ($names -join ', '), $note)
    }
}

function Resolve-TargetPortGroup {
    <#
    .SYNOPSIS
        Finds the target port group that carries the same VLAN as the source port group.
    .PARAMETER Override
        Optional explicit port group name from the CSV or from the exception mapping
        file; when supplied it wins over the VLAN lookup.
    .OUTPUTS
        PSCustomObject with Success, PortGroup, Reason and MatchedBy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceVlanInfo,
        [Parameter(Mandatory)][hashtable]$Map,
        [string]$Override,
        [object[]]$AvailablePortGroup
    )

    $result = [pscustomobject]@{
        Success   = $false
        PortGroup = $null
        MatchedBy = $null
        Reason    = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $match = @($AvailablePortGroup | Where-Object { $_.Name -eq $Override })
        if ($match.Count -eq 1) {
            $result.Success   = $true
            $result.PortGroup = $match[0]
            $result.MatchedBy = 'Override'
            return $result
        }
        if ($match.Count -eq 0) {
            $result.Reason = "Explicit target port group '$Override' does not exist on the target switch(es)."
        }
        else {
            $result.Reason = "Explicit target port group '$Override' is not unique on the target switch(es)."
        }
        return $result
    }

    if (-not $SourceVlanInfo.Key) {
        $result.Reason = "VLAN of source port group '$($SourceVlanInfo.Name)' could not be determined."
        return $result
    }

    if (-not $Map.ContainsKey($SourceVlanInfo.Key)) {
        $result.Reason = "No target port group carries $($SourceVlanInfo.Description) (source port group '$($SourceVlanInfo.Name)')."
        return $result
    }

    $candidates = @($Map[$SourceVlanInfo.Key])
    if ($candidates.Count -gt 1) {
        # Same VLAN on several target port groups - prefer an exact name match before
        # giving up, that covers the common "same name on the new VDS" case.
        $byName = @($candidates | Where-Object { $_.Name -eq $SourceVlanInfo.Name })
        if ($byName.Count -eq 1) {
            $result.Success   = $true
            $result.PortGroup = $byName[0].PortGroup
            $result.MatchedBy = 'VlanId+Name'
            return $result
        }

        $result.Reason = "$($SourceVlanInfo.Description) matches several target port groups ($(($candidates | ForEach-Object { $_.Name }) -join ', ')). Set TargetPortGroup in the CSV or add an entry to the port group exception map."
        return $result
    }

    $result.Success   = $true
    $result.PortGroup = $candidates[0].PortGroup
    $result.MatchedBy = 'VlanId'
    return $result
}

function Import-PortGroupExceptionMap {
    <#
    .SYNOPSIS
        Loads the optional exception file that pins specific source port groups to a
        specific target port group, bypassing the VLAN lookup.
    .OUTPUTS
        Hashtable: source port group name -> target port group name.
    #>
    [CmdletBinding()]
    param([string]$Path)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Path)) { return $map }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-BulkVMotionLog -Level Warning -Message "Port group exception map '$Path' was not found - continuing with VLAN based mapping only."
        return $map
    }

    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($row.SourcePortGroup) -or [string]::IsNullOrWhiteSpace($row.TargetPortGroup)) {
            Write-BulkVMotionLog -Level Warning -Message 'Ignoring incomplete row in the port group exception map (SourcePortGroup and TargetPortGroup are both required).'
            continue
        }
        $map[$row.SourcePortGroup.Trim()] = $row.TargetPortGroup.Trim()
    }

    if ($map.Count -gt 0) {
        Write-BulkVMotionLog -Message ('Loaded {0} port group exception(s) from {1}.' -f $map.Count, $Path)
        foreach ($key in ($map.Keys | Sort-Object)) {
            Write-BulkVMotionLog -Level Debug -Message ('  exception: {0} -> {1}' -f $key, $map[$key])
        }
    }

    return $map
}

#endregion VLAN / port group mapping

#region vSphere inventory helpers -----------------------------------------------

function Resolve-SourceVM {
    <#
    .SYNOPSIS
        Finds exactly one source VM, optionally scoped to a cluster to break ties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Server,
        [string]$Cluster
    )

    $vms = @(Get-VM -Name $Name -Server $Server -ErrorAction SilentlyContinue)
    if ($vms.Count -eq 0) {
        throw "VM '$Name' was not found on $($Server.Name)."
    }

    if ($vms.Count -gt 1 -and $Cluster) {
        $vms = @($vms | Where-Object { $_.VMHost -and (Get-Cluster -VMHost $_.VMHost -Server $Server -ErrorAction SilentlyContinue).Name -eq $Cluster })
    }

    if ($vms.Count -eq 0) {
        throw "VM '$Name' was not found in cluster '$Cluster' on $($Server.Name)."
    }
    if ($vms.Count -gt 1) {
        throw "VM name '$Name' is ambiguous ($($vms.Count) matches). Add a SourceCluster value to the CSV row."
    }

    # Exact, case sensitive name check - Get-VM matches case insensitively.
    if ($vms[0].Name -cne $Name) {
        Write-BulkVMotionLog -Level Warning -VMName $Name -Message "Inventory name is '$($vms[0].Name)' - the CSV value differs in casing."
    }

    return $vms[0]
}

function Select-TargetVMHost {
    <#
    .SYNOPSIS
        Picks the destination host in the target cluster.
    .DESCRIPTION
        An explicit host from the CSV always wins. Otherwise the connected, powered on
        host that is not in maintenance/standby mode and has the most free memory is
        chosen; DRS is free to rebalance the VM afterwards.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Server,
        [string]$ClusterName,
        [string]$HostName
    )

    if ($HostName) {
        $vmHost = Get-VMHost -Name $HostName -Server $Server -ErrorAction SilentlyContinue
        if (-not $vmHost) { throw "Target host '$HostName' was not found on $($Server.Name)." }
        if ($vmHost.ConnectionState -ne 'Connected') {
            throw "Target host '$HostName' is in state '$($vmHost.ConnectionState)'."
        }
        return $vmHost
    }

    if (-not $ClusterName) {
        throw 'Neither TargetCluster nor TargetHost was supplied for this VM and no default target cluster is configured.'
    }

    $cluster = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction SilentlyContinue
    if (-not $cluster) { throw "Target cluster '$ClusterName' was not found on $($Server.Name)." }

    $candidates = @(Get-VMHost -Location $cluster -Server $Server |
            Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' })

    if ($candidates.Count -eq 0) {
        throw "Target cluster '$ClusterName' has no connected host available for vMotion."
    }

    return ($candidates | Sort-Object -Property { $_.MemoryTotalGB - $_.MemoryUsageGB } -Descending | Select-Object -First 1)
}

function Resolve-TargetDatastore {
    <#
    .SYNOPSIS
        Resolves a datastore or datastore cluster by name and checks free capacity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Server,
        [double]$RequiredGB = 0,
        [double]$ReserveGB = 0
    )

    $target = Get-DatastoreCluster -Name $Name -Server $Server -ErrorAction SilentlyContinue
    if (-not $target) {
        $target = @(Get-Datastore -Name $Name -Server $Server -ErrorAction SilentlyContinue)
        if ($target.Count -gt 1) {
            throw "Datastore name '$Name' is ambiguous ($($target.Count) matches) on $($Server.Name)."
        }
        $target = $target | Select-Object -First 1
    }

    if (-not $target) { throw "Target datastore (or datastore cluster) '$Name' was not found on $($Server.Name)." }

    if ($RequiredGB -gt 0) {
        # Both Datastore and DatastoreCluster expose FreeSpaceGB.
        $freeGB = [double]$target.FreeSpaceGB
        $usableGB = $freeGB - $ReserveGB
        if ($usableGB -lt $RequiredGB) {
            throw ("Target datastore '{0}' has {1:N1} GB free ({2:N1} GB usable after the {3:N1} GB reserve) but the VM needs {4:N1} GB." -f $Name, $freeGB, $usableGB, $ReserveGB, $RequiredGB)
        }
    }

    return $target
}

function Get-SourcePortGroupCache {
    <#
    .SYNOPSIS
        Builds a portgroup-key -> VDPortgroup lookup for the source vCenter.
    .DESCRIPTION
        Matching on the port group key rather than on the name avoids picking the wrong
        port group when the same name exists on several switches or datacenters.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Server)

    $cache = @{}
    foreach ($pg in @(Get-VDPortgroup -Server $Server -ErrorAction SilentlyContinue)) {
        $key = if ($pg.ExtensionData -and $pg.ExtensionData.Key) { $pg.ExtensionData.Key } else { $pg.Key }
        if ($key) { $cache[[string]$key] = $pg }
    }
    Write-BulkVMotionLog -Level Debug -Message ('Cached {0} distributed port group(s) from the source vCenter.' -f $cache.Count)
    return $cache
}

function Get-NetworkAdapterSourcePortGroup {
    <#
    .SYNOPSIS
        Returns the port group object a VM network adapter is currently connected to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server,
        [hashtable]$PortGroupCache = @{}
    )

    $backing = $null
    if ($Adapter.ExtensionData) { $backing = $Adapter.ExtensionData.Backing }

    if ($backing) {
        $backingType = $backing.GetType().Name

        if ($backingType -like '*DistributedVirtualPortBackingInfo' -and $backing.Port -and $backing.Port.PortgroupKey) {
            $key = [string]$backing.Port.PortgroupKey
            if ($PortGroupCache.ContainsKey($key)) { return $PortGroupCache[$key] }
            throw "The distributed port group behind adapter '$($Adapter.Name)' (key $key) could not be read from the source vCenter."
        }

        if ($backingType -like '*OpaqueNetworkBackingInfo') {
            throw "Adapter '$($Adapter.Name)' is connected to an opaque network (NSX). VLAN based mapping does not apply - set TargetPortGroup for this VM in the CSV."
        }
    }

    # Standard vSwitch port group - scope the lookup to the host the VM runs on.
    $pg = @(Get-VirtualPortGroup -VMHost $VM.VMHost -Name $Adapter.NetworkName -Server $Server -Standard -ErrorAction SilentlyContinue)
    if ($pg.Count -eq 1) { return $pg[0] }

    throw "The port group '$($Adapter.NetworkName)' behind adapter '$($Adapter.Name)' could not be resolved on host '$($VM.VMHost.Name)'."
}

function Get-VMNetworkMigrationPlan {
    <#
    .SYNOPSIS
        Maps every network adapter of a VM to its target port group.
    .OUTPUTS
        PSCustomObject with Success, Adapters, PortGroups (aligned with Adapters),
        Details (human readable per adapter) and Errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][hashtable]$VlanMap,
        [object[]]$TargetPortGroup,
        [hashtable]$PortGroupCache = @{},
        [hashtable]$ExceptionMap = @{},
        [string]$Override
    )

    $adapters   = @(Get-NetworkAdapter -VM $VM -Server $Server -ErrorAction Stop)
    $resolved   = @()
    $details    = @()
    $errors     = @()

    if ($adapters.Count -eq 0) {
        Write-BulkVMotionLog -Level Warning -VMName $VM.Name -Message 'VM has no network adapters - it will be migrated without a network change.'
        return [pscustomobject]@{ Success = $true; Adapters = @(); PortGroups = @(); Details = @(); Errors = @() }
    }

    if ($Override -and $adapters.Count -gt 1) {
        Write-BulkVMotionLog -Level Warning -VMName $VM.Name -Message "TargetPortGroup '$Override' is set but the VM has $($adapters.Count) adapters - all of them will be connected to that port group."
    }

    foreach ($adapter in $adapters) {
        try {
            $sourcePg = Get-NetworkAdapterSourcePortGroup -Adapter $adapter -VM $VM -Server $Server -PortGroupCache $PortGroupCache
        }
        catch {
            $errors  += $_.Exception.Message
            $details += '{0}: <unresolved> ({1})' -f $adapter.Name, $_.Exception.Message
            continue
        }

        $vlanInfo = Get-PortGroupVlanInfo -PortGroup $sourcePg

        $pinned = $Override
        if (-not $pinned -and $ExceptionMap.ContainsKey($sourcePg.Name)) {
            $pinned = $ExceptionMap[$sourcePg.Name]
        }

        $match = Resolve-TargetPortGroup -SourceVlanInfo $vlanInfo -Map $VlanMap -Override $pinned -AvailablePortGroup $TargetPortGroup
        if (-not $match.Success) {
            $errors  += $match.Reason
            $details += '{0}: {1} ({2}) -> <unresolved>' -f $adapter.Name, $sourcePg.Name, $vlanInfo.Description
            continue
        }

        $resolved += $match.PortGroup
        $details  += '{0}: {1} ({2}) -> {3} [{4}]' -f $adapter.Name, $sourcePg.Name, $vlanInfo.Description, $match.PortGroup.Name, $match.MatchedBy
    }

    return [pscustomobject]@{
        Success    = ($errors.Count -eq 0)
        Adapters   = $adapters
        PortGroups = $resolved
        Details    = $details
        Errors     = $errors
    }
}

#endregion vSphere inventory helpers

#region Migration ---------------------------------------------------------------

function New-VMMigrationPlan {
    <#
    .SYNOPSIS
        Resolves and validates everything needed to migrate one VM.
    .DESCRIPTION
        Nothing is changed here - the plan is what -ValidateOnly prints and what the
        executor consumes. A plan with Ready = $false carries the reasons in Errors.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only builds an in-memory object; nothing is changed in vSphere or on disk.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$SourceServer,
        [Parameter(Mandatory)]$TargetServer,
        [Parameter(Mandatory)][hashtable]$VlanMap,
        [object[]]$TargetPortGroup,
        [hashtable]$PortGroupCache = @{},
        [hashtable]$ExceptionMap = @{},
        [string]$DefaultCluster,
        [string]$DefaultDatastore,
        [string]$DefaultFolder,
        [double]$DatastoreReserveGB = 0,
        [switch]$CrossVCenter
    )

    $plan = [pscustomobject]@{
        VMName         = $Row.VMName
        CsvLine        = $Row.CsvLine
        VM             = $null
        SourceCluster  = $null
        SourceHost     = $null
        TargetCluster  = if ($Row.TargetCluster) { $Row.TargetCluster } else { $DefaultCluster }
        TargetHost     = $null
        Datastore      = $null
        DatastoreName  = if ($Row.TargetDatastore) { $Row.TargetDatastore } else { $DefaultDatastore }
        Folder         = $null
        FolderName     = if ($Row.TargetFolder) { $Row.TargetFolder } else { $DefaultFolder }
        Adapters       = @()
        PortGroups     = @()
        NetworkDetails = @()
        Ready          = $false
        Errors         = @()
    }

    try {
        $plan.VM = Resolve-SourceVM -Name $Row.VMName -Server $SourceServer -Cluster $Row.SourceCluster
    }
    catch {
        $plan.Errors += $_.Exception.Message
        return $plan
    }

    $vm = $plan.VM
    $plan.SourceHost = $vm.VMHost.Name
    $sourceCluster = Get-Cluster -VMHost $vm.VMHost -Server $SourceServer -ErrorAction SilentlyContinue
    if ($sourceCluster) { $plan.SourceCluster = $sourceCluster.Name }

    if ($vm.PowerState -ne 'PoweredOn') {
        Write-BulkVMotionLog -Level Warning -VMName $vm.Name -Message "VM is $($vm.PowerState) - this will be a cold relocate, not a live vMotion."
    }

    if ($vm.ExtensionData.Runtime.Question) {
        $plan.Errors += 'The VM has a pending question in vCenter and cannot be migrated until it is answered.'
    }

    # Destination host.
    try {
        $plan.TargetHost = Select-TargetVMHost -Server $TargetServer -ClusterName $plan.TargetCluster -HostName $Row.TargetHost
        if (-not $CrossVCenter -and $plan.TargetHost.Name -eq $plan.SourceHost) {
            $plan.Errors += "The VM already runs on the selected destination host '$($plan.SourceHost)'."
        }
    }
    catch {
        $plan.Errors += $_.Exception.Message
    }

    # Destination storage.
    if ($plan.DatastoreName) {
        try {
            $requiredGB = [math]::Round([double]$vm.UsedSpaceGB, 2)
            $plan.Datastore = Resolve-TargetDatastore -Name $plan.DatastoreName -Server $TargetServer -RequiredGB $requiredGB -ReserveGB $DatastoreReserveGB
        }
        catch {
            $plan.Errors += $_.Exception.Message
        }
    }
    elseif ($CrossVCenter) {
        $plan.Errors += 'A target datastore is required for a cross vCenter migration. Set TargetDatastore in the CSV or use -DefaultTargetDatastore.'
    }

    # Destination folder.
    if ($plan.FolderName) {
        $folder = @(Get-Folder -Name $plan.FolderName -Type VM -Server $TargetServer -ErrorAction SilentlyContinue)
        if ($folder.Count -eq 1) { $plan.Folder = $folder[0] }
        elseif ($folder.Count -eq 0) { $plan.Errors += "Target VM folder '$($plan.FolderName)' was not found on $($TargetServer.Name)." }
        else { $plan.Errors += "Target VM folder '$($plan.FolderName)' is ambiguous ($($folder.Count) matches) on $($TargetServer.Name)." }
    }

    # Networking - the VDS/port group remap.
    try {
        $network = Get-VMNetworkMigrationPlan -VM $vm -Server $SourceServer -VlanMap $VlanMap `
            -TargetPortGroup $TargetPortGroup -PortGroupCache $PortGroupCache `
            -ExceptionMap $ExceptionMap -Override $Row.TargetPortGroup

        $plan.Adapters       = $network.Adapters
        $plan.PortGroups     = $network.PortGroups
        $plan.NetworkDetails = $network.Details
        if (-not $network.Success) { $plan.Errors += $network.Errors }
    }
    catch {
        $plan.Errors += "Network mapping failed: $($_.Exception.Message)"
    }

    $plan.Ready = ($plan.Errors.Count -eq 0)
    return $plan
}

function Write-MigrationPlanReport {
    <#
    .SYNOPSIS
        Logs a resolved plan for one VM.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $vmName = $Plan.VMName
    Write-BulkVMotionLog -VMName $vmName -Message ('Source      : host {0}, cluster {1}' -f $Plan.SourceHost, $Plan.SourceCluster)
    Write-BulkVMotionLog -VMName $vmName -Message ('Destination : host {0}, cluster {1}' -f $(if ($Plan.TargetHost) { $Plan.TargetHost.Name } else { '<unresolved>' }), $Plan.TargetCluster)
    Write-BulkVMotionLog -VMName $vmName -Message ('Datastore   : {0}' -f $(if ($Plan.Datastore) { $Plan.Datastore.Name } else { '<unchanged>' }))
    if ($Plan.FolderName) {
        Write-BulkVMotionLog -VMName $vmName -Message ('Folder      : {0}' -f $Plan.FolderName)
    }
    foreach ($detail in $Plan.NetworkDetails) {
        Write-BulkVMotionLog -VMName $vmName -Message ('Network     : {0}' -f $detail)
    }
    foreach ($problem in $Plan.Errors) {
        Write-BulkVMotionLog -Level Error -VMName $vmName -Message $problem
    }
}

function Start-VMMigrationTask {
    <#
    .SYNOPSIS
        Starts the vMotion for one planned VM and returns the vCenter task.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'ShouldProcess is handled by the calling script, which prompts once per VM before this is reached.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [ValidateSet('Low', 'Standard', 'High')][string]$VMotionPriority = 'High',
        [ValidateSet('Thin', 'Thick', 'EagerZeroedThick', 'AsDefined')][string]$DiskStorageFormat = 'AsDefined'
    )

    $params = @{
        VM          = $Plan.VM
        Destination = $Plan.TargetHost
        RunAsync    = $true
        Confirm     = $false
        ErrorAction = 'Stop'
    }

    if ($Plan.Adapters.Count -gt 0) {
        # Move-VM pairs the two lists positionally, so a mismatch would silently connect
        # an adapter to the wrong network. A ready plan always resolves one port group
        # per adapter, so treat anything else as a bug rather than working around it.
        if ($Plan.PortGroups.Count -ne $Plan.Adapters.Count) {
            throw "Internal error: $($Plan.Adapters.Count) network adapter(s) but $($Plan.PortGroups.Count) resolved port group(s) for '$($Plan.VMName)'."
        }
        $params.NetworkAdapter = $Plan.Adapters
        $params.PortGroup      = $Plan.PortGroups
    }

    if ($Plan.Datastore) {
        $params.Datastore = $Plan.Datastore
        if ($DiskStorageFormat -ne 'AsDefined') { $params.DiskStorageFormat = $DiskStorageFormat }
    }
    if ($Plan.Folder) { $params.InventoryLocation = $Plan.Folder }
    if ($Plan.VM.PowerState -eq 'PoweredOn') { $params.VMotionPriority = $VMotionPriority }

    return (Move-VM @params)
}

function Wait-VMMigrationTask {
    <#
    .SYNOPSIS
        Polls running migration tasks and reports progress.
    .DESCRIPTION
        Takes the tracker objects created by the runner script, refreshes each task and
        marks it Completed/Failed/TimedOut. Returns the trackers that are still running.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tracker,
        [int]$TimeoutMinutes = 120,
        [int]$ProgressStep = 20
    )

    $stillRunning = @()

    foreach ($item in $Tracker) {
        $task = Get-Task -Id $item.Task.Id -ErrorAction SilentlyContinue
        if (-not $task) {
            $item.Status  = 'Failed'
            $item.Message = 'The vCenter task disappeared before it completed.'
            $item.End     = Get-Date
            Write-BulkVMotionLog -Level Error -VMName $item.VMName -Message $item.Message
            continue
        }

        $item.Task = $task

        switch ($task.State) {
            'Success' {
                $item.Status  = 'Success'
                $item.End     = Get-Date
                $item.Message = 'Migration completed.'
                Write-BulkVMotionLog -Level Success -VMName $item.VMName -Message ('Migration completed in {0:N1} minutes.' -f ($item.End - $item.Start).TotalMinutes)
            }
            'Error' {
                $item.Status  = 'Failed'
                $item.End     = Get-Date
                $detail = if ($task.ExtensionData -and $task.ExtensionData.Info -and $task.ExtensionData.Info.Error) {
                    $task.ExtensionData.Info.Error.LocalizedMessage
                }
                else { 'Unknown error' }
                $item.Message = $detail
                Write-BulkVMotionLog -Level Error -VMName $item.VMName -Message ('Migration failed: {0}' -f $detail)
            }
            default {
                $elapsed = (Get-Date) - $item.Start
                if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
                    $item.Status  = 'TimedOut'
                    $item.End     = Get-Date
                    $item.Message = "The migration did not finish within the $TimeoutMinutes minute timeout. The vCenter task is still running - check it in vCenter."
                    Write-BulkVMotionLog -Level Error -VMName $item.VMName -Message $item.Message
                    continue
                }

                $percent = [int]$task.PercentComplete
                if ($percent -ge ($item.LastReportedPercent + $ProgressStep)) {
                    $item.LastReportedPercent = $percent - ($percent % $ProgressStep)
                    Write-BulkVMotionLog -VMName $item.VMName -Message ('Migration {0}% complete ({1:N1} minutes elapsed).' -f $percent, $elapsed.TotalMinutes)
                }
                $stillRunning += $item
            }
        }
    }

    return $stillRunning
}

function New-MigrationTracker {
    <#
    .SYNOPSIS
        Creates the per-VM state object used to follow a migration from start to result.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only builds an in-memory object; nothing is changed in vSphere or on disk.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        $Task,
        [ValidateSet('Running', 'Success', 'Failed', 'TimedOut', 'Skipped')][string]$Status = 'Running',
        [string]$Message
    )

    return [pscustomobject]@{
        VMName              = $Plan.VMName
        CsvLine             = $Plan.CsvLine
        Plan                = $Plan
        Task                = $Task
        Status              = $Status
        Message             = $Message
        Start               = Get-Date
        End                 = $null
        LastReportedPercent = 0
    }
}

function ConvertTo-MigrationResult {
    <#
    .SYNOPSIS
        Flattens a tracker into the row written to the per-run result CSV.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Tracker)

    process {
        $plan = $Tracker.Plan
        [pscustomobject]@{
            Timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            VMName          = $Tracker.VMName
            Status          = $Tracker.Status
            SourceCluster   = $plan.SourceCluster
            SourceHost      = $plan.SourceHost
            TargetCluster   = $plan.TargetCluster
            TargetHost      = if ($plan.TargetHost) { $plan.TargetHost.Name } else { '' }
            TargetDatastore = if ($plan.Datastore) { $plan.Datastore.Name } else { '' }
            NetworkMapping  = ($plan.NetworkDetails -join ' | ')
            DurationMinutes = if ($Tracker.End) { [math]::Round(($Tracker.End - $Tracker.Start).TotalMinutes, 2) } else { '' }
            Message         = $Tracker.Message
            CsvLine         = $Tracker.CsvLine
        }
    }
}

#endregion Migration

Export-ModuleMember -Function @(
    'Start-BulkVMotionLog'
    'Stop-BulkVMotionLog'
    'Write-BulkVMotionLog'
    'Get-BulkVMotionLogFile'
    'Import-MigrationCsv'
    'Move-ProcessedCsv'
    'Get-PortGroupVlanInfo'
    'Get-VlanPortGroupMap'
    'Write-VlanPortGroupMapReport'
    'Resolve-TargetPortGroup'
    'Import-PortGroupExceptionMap'
    'Resolve-SourceVM'
    'Select-TargetVMHost'
    'Resolve-TargetDatastore'
    'Get-SourcePortGroupCache'
    'Get-NetworkAdapterSourcePortGroup'
    'Get-VMNetworkMigrationPlan'
    'New-VMMigrationPlan'
    'Write-MigrationPlanReport'
    'Start-VMMigrationTask'
    'Wait-VMMigrationTask'
    'New-MigrationTracker'
    'ConvertTo-MigrationResult'
)
