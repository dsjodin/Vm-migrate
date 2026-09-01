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

# Columns the operator authors. Each phase has its own target columns so one file can
# carry the whole journey; the generic Target* columns are the fallback for a simple
# single phase file.
$script:PlanCsvColumns = @(
    'VMName', 'SourceCluster', 'Notes'
    'Phase1Cluster', 'Phase1Host', 'Phase1PortGroup'
    'Phase2Datastore'
    'Phase3Cluster', 'Phase3Host', 'Phase3PortGroup'
    'TargetCluster', 'TargetHost', 'TargetDatastore', 'TargetFolder', 'TargetPortGroup'
)

# Columns the script writes back before archiving the file, so the CSV becomes the
# record of where each VM actually landed.
$script:ResultCsvColumns = @(
    'PhaseCompleted', 'CompletedAt', 'ResultVIServer', 'ResultCluster',
    'ResultHost', 'ResultDatastore', 'ResultPortGroup'
)

$script:KnownCsvColumns = $script:PlanCsvColumns + $script:ResultCsvColumns

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

        # 0 means "no phase completed yet", so a fresh file starts at phase 1.
        $completed = 0
        if (-not [string]::IsNullOrWhiteSpace($normalized['PhaseCompleted'])) {
            $parsed = 0
            if ([int]::TryParse($normalized['PhaseCompleted'], [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 3) {
                $completed = $parsed
            }
            else {
                throw "CSV line $lineNumber has an invalid PhaseCompleted value '$($normalized['PhaseCompleted'])'. Expected 0, 1, 2 or 3."
            }
        }
        $normalized['PhaseCompleted'] = $completed

        [pscustomobject]$normalized
    }
}

function Get-CsvNextPhase {
    <#
    .SYNOPSIS
        Works out which migration phase a CSV file is due for.
    .DESCRIPTION
        Every row records the phase it has completed, so the file itself carries the
        state of the wave. The next phase is one past the least advanced row: a wave
        where 8 of 10 VMs finished phase 1 is still a phase 1 file, and re-running it
        picks up the two that are behind.
    .PARAMETER Assert
        The phase the operator said this run is. When it disagrees with the file, the
        file is rejected rather than migrated - that is what stops a phase 2 file
        dropped into IN from being put through a phase 1 wave.
    .OUTPUTS
        PSCustomObject with Phase, IsComplete, Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Row,
        # 0 means the run did not state a phase, so there is nothing to assert.
        [ValidateRange(0, 3)][int]$Assert = 0
    )

    $completed = @($Row | ForEach-Object { [int]$_.PhaseCompleted })
    $lowest    = ($completed | Measure-Object -Minimum).Minimum
    $highest   = ($completed | Measure-Object -Maximum).Maximum
    $next      = $lowest + 1

    $result = [pscustomobject]@{
        Phase      = $next
        IsComplete = ($next -gt 3)
        Reason     = $null
    }

    if ($lowest -ne $highest) {
        Write-BulkVMotionLog -Level Warning -Message "The file is part way through phase $next - $(@($completed | Where-Object { $_ -eq $lowest }).Count) of $($completed.Count) VM(s) still have it to do."
    }

    if ($Assert -gt 0 -and -not $result.IsComplete -and $Assert -ne $next) {
        $result.Reason = "The file is due for phase $next but the run was started with -Phase $Assert. Nothing was migrated."
    }
    elseif ($Assert -gt 0 -and $result.IsComplete) {
        $result.Reason = "Every VM in the file has completed phase 3, so there is no phase $Assert left to run."
    }

    return $result
}

function Get-PhaseRowValue {
    <#
    .SYNOPSIS
        Reads a target value for the phase being run.
    .DESCRIPTION
        Precedence is: the phase specific column (Phase1Cluster), then the generic
        column (TargetCluster), then the run level default. That lets one file describe
        all three phases while a simple single phase file keeps working unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$PhaseColumn,
        [string]$GenericColumn,
        [string]$Default
    )

    $property = $Row.PSObject.Properties[$PhaseColumn]
    if ($property -and -not [string]::IsNullOrWhiteSpace($property.Value)) { return [string]$property.Value }

    if ($GenericColumn) {
        $property = $Row.PSObject.Properties[$GenericColumn]
        if ($property -and -not [string]::IsNullOrWhiteSpace($property.Value)) { return [string]$property.Value }
    }

    return $Default
}

function Update-MigrationCsv {
    <#
    .SYNOPSIS
        Writes the outcome of a phase back into the CSV file.
    .DESCRIPTION
        Rows that completed the phase get PhaseCompleted, CompletedAt and where the VM
        landed; rows that failed keep the phase they were already at, so a re-run knows
        what is still outstanding. Author columns and row order are preserved, and every
        row is given the same set of columns so Export-Csv cannot drop one.
    .PARAMETER Update
        One object per completed row: CsvLine plus the values to record.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Update
    )

    if ($Update.Count -eq 0) { return }

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { return }

    $byLine = @{}
    foreach ($item in $Update) { $byLine[[int]$item.CsvLine] = $item }

    # Union of what the file already has and what this run adds.
    $columns = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $rows[0].PSObject.Properties.Name) { if (-not $columns.Contains($name)) { $columns.Add($name) } }
    foreach ($name in $script:ResultCsvColumns) { if (-not $columns.Contains($name)) { $columns.Add($name) } }

    $updated = @()
    $lineNumber = 1
    foreach ($row in $rows) {
        $lineNumber++
        $record = [ordered]@{}
        foreach ($name in $columns) {
            $property = $row.PSObject.Properties[$name]
            $record[$name] = if ($property) { $property.Value } else { '' }
        }

        if ($byLine.ContainsKey($lineNumber)) {
            $outcome = $byLine[$lineNumber]
            foreach ($name in $script:ResultCsvColumns) {
                $property = $outcome.PSObject.Properties[$name]
                if ($property) { $record[$name] = $property.Value }
            }
        }

        # A row that has not completed anything reads as 0 rather than blank, so the
        # column means the same thing on every line of the file.
        if ([string]::IsNullOrWhiteSpace([string]$record['PhaseCompleted'])) { $record['PhaseCompleted'] = 0 }

        $updated += [pscustomobject]$record
    }

    if ($PSCmdlet.ShouldProcess($Path, "Record the phase result for $($Update.Count) VM(s)")) {
        $updated | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
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

function Get-VMDatastoreNotVisibleToHost {
    <#
    .SYNOPSIS
        Lists the VM's datastores that the destination host cannot see.
    .DESCRIPTION
        Phase 1 moves compute and networking but leaves the disks where they are, so a
        destination host that has not got the VM's datastores mounted would fail the
        vMotion. Catching it in the plan turns a failed migration into a clear message.

        When the host's datastores cannot be read nothing is reported - vCenter will
        still refuse an impossible migration, and a guess here would fail good VMs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$VMHost,
        [Parameter(Mandatory)]$SourceServer,
        [Parameter(Mandatory)]$TargetServer
    )

    $vmDatastores = @(Get-Datastore -VM $VM -Server $SourceServer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($vmDatastores.Count -eq 0) { return @() }

    $hostDatastores = @(Get-Datastore -VMHost $VMHost -Server $TargetServer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($hostDatastores.Count -eq 0) {
        Write-BulkVMotionLog -Level Debug -VMName $VM.Name -Message "Could not read the datastores of host '$($VMHost.Name)' - skipping the storage visibility check."
        return @()
    }

    return @($vmDatastores | Where-Object { $_ -notin $hostDatastores })
}

function Test-VMOnTargetDatastore {
    <#
    .SYNOPSIS
        Tells whether every disk of the VM already lives on the target datastore.
    .DESCRIPTION
        When the target is a datastore cluster, any member datastore counts. Used to
        decide whether a storage move is needed at all - within one vCenter two
        clusters often share storage, so the move is frequently compute + network only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Server
    )

    $current = @(Get-Datastore -VM $VM -Server $Server -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($current.Count -eq 0) { return $false }

    # For a datastore cluster this returns its members; for a plain datastore it
    # returns nothing and the single name is used.
    $accepted = @(Get-Datastore -Location $Target -Server $Server -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($accepted.Count -eq 0) { $accepted = @($Target.Name) }

    return (@($current | Where-Object { $_ -notin $accepted }).Count -eq 0)
}

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
    $mappings   = @()

    if ($adapters.Count -eq 0) {
        Write-BulkVMotionLog -Level Warning -VMName $VM.Name -Message 'VM has no network adapters - it will be migrated without a network change.'
        return [pscustomobject]@{ Success = $true; Adapters = @(); PortGroups = @(); Details = @(); Errors = @(); Mappings = @(); NetworkChangeNeeded = $false }
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
        $alreadyThere = ($sourcePg.Name -eq $match.PortGroup.Name)
        $suffix = if ($alreadyThere) { ' (already connected)' } else { '' }
        $details  += '{0}: {1} ({2}) -> {3} [{4}]{5}' -f $adapter.Name, $sourcePg.Name, $vlanInfo.Description, $match.PortGroup.Name, $match.MatchedBy, $suffix
        $mappings += [pscustomobject]@{
            Adapter         = $adapter
            AdapterName     = $adapter.Name
            SourceName      = $sourcePg.Name
            TargetPortGroup = $match.PortGroup
            TargetName      = $match.PortGroup.Name
            AlreadyConnected = $alreadyThere
        }
    }

    return [pscustomobject]@{
        Success             = ($errors.Count -eq 0)
        Adapters            = $adapters
        PortGroups          = $resolved
        Details             = $details
        Errors              = $errors
        Mappings            = $mappings
        NetworkChangeNeeded = @($mappings | Where-Object { -not $_.AlreadyConnected }).Count -gt 0
    }
}

#endregion vSphere inventory helpers

#region Migration ---------------------------------------------------------------

function New-VMMigrationPlan {
    <#
    .SYNOPSIS
        Resolves and validates everything one VM needs for the phase being run.
    .DESCRIPTION
        Nothing is changed here - the plan is what -ValidateOnly prints and what the
        executor consumes. A plan with Ready = $false carries the reasons in Errors.

        Each phase is deliberately narrow, so a mistake in one column cannot turn into
        an unintended migration of a different kind:

          Phase 1  cluster change plus the VDS/port group remap. Storage is never
                   touched, so the target cluster must already see the VM's datastores.
          Phase 2  storage only. The VM stays on its host and keeps its networking.
          Phase 3  cross vCenter. The VM keeps the same shared datastore, which is
                   resolved again on the new vCenter, and the port groups are remapped
                   onto the new vCenter's VDS.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only builds an in-memory object; nothing is changed in vSphere or on disk.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Phase,
        [Parameter(Mandatory)]$SourceServer,
        [Parameter(Mandatory)]$TargetServer,
        [hashtable]$VlanMap = @{},
        [object[]]$TargetPortGroup,
        [hashtable]$PortGroupCache = @{},
        [hashtable]$ExceptionMap = @{},
        [string]$DefaultCluster,
        [string]$DefaultDatastore,
        [string]$DefaultFolder,
        [double]$DatastoreReserveGB = 0
    )

    $crossVCenter = ($Phase -eq 3)

    $plan = [pscustomobject]@{
        VMName         = $Row.VMName
        CsvLine        = $Row.CsvLine
        Phase          = $Phase
        VM             = $null
        SourceCluster  = $null
        SourceHost     = $null
        TargetCluster  = $null
        TargetHost     = $null
        Datastore      = $null
        DatastoreName  = $null
        Folder         = $null
        FolderName     = Get-PhaseRowValue -Row $Row -PhaseColumn 'TargetFolder' -Default $DefaultFolder
        Adapters       = @()
        PortGroups     = @()
        NetworkDetails = @()
        ChangesCompute = $false
        ChangesStorage = $false
        ChangesNetwork = $false
        NetworkOnly    = $false
        StorageOnly    = $false
        AlreadyInPlace = $false
        Ready          = $false
        Errors         = @()
    }

    switch ($Phase) {
        1 {
            $plan.TargetCluster = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase1Cluster' -GenericColumn 'TargetCluster' -Default $DefaultCluster
            $portGroupOverride  = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase1PortGroup' -GenericColumn 'TargetPortGroup'
            $hostOverride       = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase1Host' -GenericColumn 'TargetHost'
        }
        2 {
            $plan.DatastoreName = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase2Datastore' -GenericColumn 'TargetDatastore' -Default $DefaultDatastore
            $portGroupOverride  = $null
            $hostOverride       = $null
        }
        3 {
            $plan.TargetCluster = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase3Cluster' -GenericColumn 'TargetCluster' -Default $DefaultCluster
            $portGroupOverride  = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase3PortGroup' -GenericColumn 'TargetPortGroup'
            $hostOverride       = Get-PhaseRowValue -Row $Row -PhaseColumn 'Phase3Host' -GenericColumn 'TargetHost'
        }
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
        Write-BulkVMotionLog -Level Warning -VMName $vm.Name -Message "VM is $($vm.PowerState) - this will be a cold relocate, not a live migration."
    }

    if ($vm.ExtensionData.Runtime.Question) {
        $plan.Errors += 'The VM has a pending question in vCenter and cannot be migrated until it is answered.'
    }

    #region Destination host --------------------------------------------------

    if ($Phase -eq 2) {
        # Storage only: the VM does not leave the host it is on.
        $plan.TargetHost     = $vm.VMHost
        $plan.TargetCluster  = $plan.SourceCluster
        $plan.ChangesCompute = $false
    }
    else {
        # A VM already in the target cluster keeps the host DRS gave it, so re-running
        # a wave does not shuffle VMs around for no reason.
        $inTargetCluster = (-not $crossVCenter) -and $plan.TargetCluster -and ($plan.SourceCluster -eq $plan.TargetCluster)

        try {
            if ($inTargetCluster -and -not $hostOverride) {
                $plan.TargetHost = $vm.VMHost
            }
            else {
                $plan.TargetHost = Select-TargetVMHost -Server $TargetServer -ClusterName $plan.TargetCluster -HostName $hostOverride
            }
            $plan.ChangesCompute = $crossVCenter -or ($plan.TargetHost.Name -ne $plan.SourceHost)
        }
        catch {
            $plan.Errors += $_.Exception.Message
        }
    }

    #endregion Destination host

    #region Storage -----------------------------------------------------------

    if ($Phase -eq 2) {
        if (-not $plan.DatastoreName) {
            $plan.Errors += 'Phase 2 is the storage move, so a target datastore is required. Set Phase2Datastore in the CSV or use -DefaultTargetDatastore.'
        }
        else {
            try {
                $candidate = Resolve-TargetDatastore -Name $plan.DatastoreName -Server $TargetServer
                if (Test-VMOnTargetDatastore -VM $vm -Target $candidate -Server $TargetServer) {
                    $plan.ChangesStorage = $false
                    Write-BulkVMotionLog -Level Debug -VMName $vm.Name -Message "Already on '$($plan.DatastoreName)' - no storage move needed."
                }
                else {
                    $requiredGB = [math]::Round([double]$vm.UsedSpaceGB, 2)
                    $plan.Datastore = Resolve-TargetDatastore -Name $plan.DatastoreName -Server $TargetServer -RequiredGB $requiredGB -ReserveGB $DatastoreReserveGB
                    $plan.ChangesStorage = $true
                }
            }
            catch {
                $plan.Errors += $_.Exception.Message
            }
        }
    }
    elseif ($Phase -eq 1) {
        # Storage stays put, so the destination hosts have to be able to see it.
        if ($plan.TargetHost) {
            $unreachable = Get-VMDatastoreNotVisibleToHost -VM $vm -VMHost $plan.TargetHost -SourceServer $SourceServer -TargetServer $TargetServer
            foreach ($name in $unreachable) {
                $plan.Errors += "Datastore '$name' is not mounted on the destination host '$($plan.TargetHost.Name)'. Phase 1 does not move storage, so the VM cannot run there."
            }
        }
    }
    else {
        # Phase 3 keeps the same shared storage, but Move-VM needs that datastore as the
        # new vCenter sees it. If it is not there, the shared storage assumption is wrong.
        $currentDatastores = @(Get-Datastore -VM $vm -Server $SourceServer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        if ($currentDatastores.Count -eq 0) {
            $plan.Errors += 'The datastores currently used by the VM could not be read.'
        }
        elseif ($currentDatastores.Count -gt 1) {
            $plan.Errors += "The VM spans several datastores ($($currentDatastores -join ', ')). Cross vCenter migration with unchanged storage needs a single datastore."
        }
        else {
            $plan.DatastoreName = $currentDatastores[0]
            try {
                # No free space check: the data is not going anywhere, it is the same volume.
                $plan.Datastore = Resolve-TargetDatastore -Name $plan.DatastoreName -Server $TargetServer
                $plan.ChangesStorage = $false
            }
            catch {
                $plan.Errors += "Datastore '$($plan.DatastoreName)' was not found on $($TargetServer.Name). Phase 3 expects the same shared storage to be presented to both vCenters."
            }
        }
    }

    #endregion Storage

    #region Destination folder ------------------------------------------------

    if ($plan.FolderName) {
        $folder = @(Get-Folder -Name $plan.FolderName -Type VM -Server $TargetServer -ErrorAction SilentlyContinue)
        if ($folder.Count -eq 1) { $plan.Folder = $folder[0] }
        elseif ($folder.Count -eq 0) { $plan.Errors += "Target VM folder '$($plan.FolderName)' was not found on $($TargetServer.Name)." }
        else { $plan.Errors += "Target VM folder '$($plan.FolderName)' is ambiguous ($($folder.Count) matches) on $($TargetServer.Name)." }
    }

    #endregion Destination folder

    #region Networking --------------------------------------------------------

    if ($Phase -eq 2) {
        # Storage only - the adapters are left exactly as they are.
        $plan.Adapters       = @(Get-NetworkAdapter -VM $vm -Server $SourceServer -ErrorAction SilentlyContinue)
        $plan.ChangesNetwork = $false
    }
    else {
        try {
            $network = Get-VMNetworkMigrationPlan -VM $vm -Server $SourceServer -VlanMap $VlanMap `
                -TargetPortGroup $TargetPortGroup -PortGroupCache $PortGroupCache `
                -ExceptionMap $ExceptionMap -Override $portGroupOverride

            $plan.Adapters       = $network.Adapters
            $plan.PortGroups     = $network.PortGroups
            $plan.NetworkDetails = $network.Details
            $plan.ChangesNetwork = $network.NetworkChangeNeeded
            if (-not $network.Success) { $plan.Errors += $network.Errors }
        }
        catch {
            $plan.Errors += "Network mapping failed: $($_.Exception.Message)"
        }
    }

    #endregion Networking

    $plan.Ready = ($plan.Errors.Count -eq 0)

    if ($plan.Ready) {
        # Nothing left to do means an earlier run already did this phase for this VM.
        $plan.AlreadyInPlace = -not ($plan.ChangesCompute -or $plan.ChangesStorage -or $plan.ChangesNetwork)

        # Only the port groups differ: reconnect the adapters, because Move-VM would be
        # asked for a relocate that moves nothing.
        $plan.NetworkOnly = $plan.ChangesNetwork -and -not $plan.ChangesCompute -and -not $plan.ChangesStorage

        # Only the storage differs: a plain Storage vMotion, with no destination host.
        $plan.StorageOnly = $plan.ChangesStorage -and -not $plan.ChangesCompute -and -not $plan.ChangesNetwork
    }

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
    Write-BulkVMotionLog -VMName $vmName -Message ('Phase       : {0}' -f $Plan.Phase)
    Write-BulkVMotionLog -VMName $vmName -Message ('Source      : host {0}, cluster {1}' -f $Plan.SourceHost, $Plan.SourceCluster)
    Write-BulkVMotionLog -VMName $vmName -Message ('Destination : host {0}, cluster {1}' -f $(if ($Plan.TargetHost) { $Plan.TargetHost.Name } else { '<unresolved>' }), $Plan.TargetCluster)
    Write-BulkVMotionLog -VMName $vmName -Message ('Datastore   : {0}' -f $(if ($Plan.Datastore) { $Plan.Datastore.Name } else { '<unchanged>' }))
    if ($Plan.FolderName) {
        Write-BulkVMotionLog -VMName $vmName -Message ('Folder      : {0}' -f $Plan.FolderName)
    }
    foreach ($detail in $Plan.NetworkDetails) {
        Write-BulkVMotionLog -VMName $vmName -Message ('Network     : {0}' -f $detail)
    }

    $changes = @()
    if ($Plan.ChangesCompute) { $changes += 'compute' }
    if ($Plan.ChangesStorage) { $changes += 'storage' }
    if ($Plan.ChangesNetwork) { $changes += 'network' }
    $summary = if ($changes.Count -gt 0) { $changes -join ' + ' } else { 'nothing - the VM is already where the CSV wants it' }
    Write-BulkVMotionLog -VMName $vmName -Message ('Will change : {0}' -f $summary)
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

    # The VM is already on the right host and storage - only the adapters have to be
    # reconnected. Move-VM would be asked to relocate a VM that is not going anywhere,
    # so reconfigure the adapters instead. This is quick, so it runs synchronously and
    # the caller gets $null instead of a task.
    if ($Plan.NetworkOnly) {
        for ($i = 0; $i -lt $Plan.Adapters.Count; $i++) {
            Set-NetworkAdapter -NetworkAdapter $Plan.Adapters[$i] -Portgroup $Plan.PortGroups[$i] -Confirm:$false -ErrorAction Stop | Out-Null
        }
        return $null
    }

    $params = @{
        VM          = $Plan.VM
        RunAsync    = $true
        Confirm     = $false
        ErrorAction = 'Stop'
    }

    # A pure Storage vMotion must not name a destination host: the VM is not going
    # anywhere, and Move-VM would treat that as a relocate to the host it is already on.
    if (-not $Plan.StorageOnly) { $params.Destination = $Plan.TargetHost }

    if ($Plan.Adapters.Count -gt 0 -and $Plan.ChangesNetwork) {
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
        # Phase 3 passes the datastore even though no data moves - a cross vCenter
        # relocate needs the volume as the receiving vCenter sees it.
        $params.Datastore = $Plan.Datastore
        if ($Plan.ChangesStorage -and $DiskStorageFormat -ne 'AsDefined') {
            $params.DiskStorageFormat = $DiskStorageFormat
        }
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
        [ValidateSet('Running', 'Success', 'Failed', 'TimedOut', 'Skipped', 'AlreadyDone')][string]$Status = 'Running',
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
            Phase           = $plan.Phase
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
    'Get-CsvNextPhase'
    'Get-PhaseRowValue'
    'Update-MigrationCsv'
    'Get-PortGroupVlanInfo'
    'Get-VlanPortGroupMap'
    'Write-VlanPortGroupMapReport'
    'Resolve-TargetPortGroup'
    'Import-PortGroupExceptionMap'
    'Resolve-SourceVM'
    'Select-TargetVMHost'
    'Resolve-TargetDatastore'
    'Test-VMOnTargetDatastore'
    'Get-VMDatastoreNotVisibleToHost'
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
