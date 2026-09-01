<#
.SYNOPSIS
    Bulk vMotion of VMs listed in CSV files, from one vSphere cluster to another,
    including a VDS change where the target port group is found by VLAN ID.

.DESCRIPTION
    Every CSV file in the IN folder is processed in turn:

      1. the file is read and validated,
      2. each VM is resolved and a migration plan is built (destination host,
         datastore, folder and the target port group for every network adapter),
      3. the VMs are migrated (a configurable number at a time),
      4. when every VM in the file has been processed the CSV is moved to the
         MOVED folder and a result CSV is written next to the run log.

    The target port group for each adapter is found by reading the VLAN ID of the
    port group the adapter is on today and looking for the port group on the target
    VDS that carries the same VLAN. Exceptions can be pinned per VM (TargetPortGroup
    column) or per source port group (config/portgroup-exceptions.csv).

    Everything the run does is written to the console and to a log file in the LOGS
    folder.

.PARAMETER SourceVIServer
    vCenter that hosts the VMs today.

.PARAMETER TargetVIServer
    vCenter that owns the new cluster. Omit it when both clusters live in the same
    vCenter; supply it for a cross vCenter (xVC) vMotion.

.PARAMETER TargetVDSwitch
    Name of the new distributed switch (or several). When omitted, every distributed
    port group visible on the target vCenter is considered.

.PARAMETER ValidateOnly
    Resolve and report everything, but do not migrate and do not move the CSV file.
    Run this first - it is the dry run.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -SourceVIServer vc-old.corp.local -TargetVIServer vc-new.corp.local `
        -TargetVDSwitch 'VDS-NEW' -DefaultTargetCluster 'CL-NEW-01' -ValidateOnly

    Dry run: shows the VLAN table, the resolved port groups and any problem, without
    touching a single VM.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -SourceVIServer vc-old.corp.local -TargetVIServer vc-new.corp.local `
        -TargetVDSwitch 'VDS-NEW' -DefaultTargetCluster 'CL-NEW-01' -MaxConcurrentMigrations 4

    Migrates every VM in every CSV in the IN folder, four at a time.

.NOTES
    Requires PowerCLI 12.0 or later (VMware.VimAutomation.Core / VMware.VimAutomation.Vds).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$SourceVIServer,

    [string]$TargetVIServer,

    [System.Management.Automation.PSCredential]$SourceCredential,

    [System.Management.Automation.PSCredential]$TargetCredential,

    [string[]]$TargetVDSwitch,

    [string]$DefaultTargetCluster,

    [string]$DefaultTargetDatastore,

    [string]$DefaultTargetFolder,

    [string]$InFolder,

    [string]$MovedFolder,

    [string]$LogFolder,

    # Process a single CSV instead of everything in the IN folder.
    [string]$CsvFile,

    [string]$PortGroupExceptionMap,

    [ValidateRange(1, 16)]
    [int]$MaxConcurrentMigrations = 2,

    [ValidateRange(1, 1440)]
    [int]$MigrationTimeoutMinutes = 120,

    [ValidateRange(5, 600)]
    [int]$PollIntervalSeconds = 15,

    [ValidateSet('Low', 'Standard', 'High')]
    [string]$VMotionPriority = 'High',

    [ValidateSet('Thin', 'Thick', 'EagerZeroedThick', 'AsDefined')]
    [string]$DiskStorageFormat = 'AsDefined',

    # Free space that must remain on the target datastore after the VM lands there.
    [double]$DatastoreReserveGB = 100,

    [ValidateSet('AllSuccess', 'Always', 'Never')]
    [string]$MoveCsvWhen = 'AllSuccess',

    # Stop starting new migrations from a file as soon as one VM fails.
    [switch]$StopOnError,

    [switch]$ValidateOnly,

    [switch]$IgnoreInvalidCertificate,

    [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
    [string]$LogLevel = 'Info',

    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

#region Configuration file ------------------------------------------------------

# Values from the JSON config are applied only to parameters that were not passed
# on the command line, so an explicit argument always wins.
if (-not $ConfigFile) {
    $defaultConfig = Join-Path (Join-Path $scriptRoot 'config') 'settings.json'
    if (Test-Path -LiteralPath $defaultConfig) { $ConfigFile = $defaultConfig }
}

if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Configuration file not found: $ConfigFile" }
    $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    foreach ($property in $config.PSObject.Properties) {
        if ($PSBoundParameters.ContainsKey($property.Name)) { continue }
        if ($null -eq $property.Value -or ('' -eq $property.Value)) { continue }
        if (-not (Get-Variable -Name $property.Name -Scope 0 -ErrorAction SilentlyContinue)) { continue }
        Set-Variable -Name $property.Name -Value $property.Value -Scope 0
    }
}

if (-not $InFolder)    { $InFolder    = Join-Path $scriptRoot 'IN' }
if (-not $MovedFolder) { $MovedFolder = Join-Path $scriptRoot 'MOVED' }
if (-not $LogFolder)   { $LogFolder   = Join-Path $scriptRoot 'LOGS' }
if (-not $PortGroupExceptionMap) {
    $candidate = Join-Path (Join-Path $scriptRoot 'config') 'portgroup-exceptions.csv'
    if (Test-Path -LiteralPath $candidate) { $PortGroupExceptionMap = $candidate }
}

foreach ($folder in @($InFolder, $MovedFolder, $LogFolder)) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
}

#endregion Configuration file

#region Module loading ----------------------------------------------------------

Import-Module (Join-Path (Join-Path (Join-Path $scriptRoot 'Modules') 'BulkVMotion') 'BulkVMotion.psd1') -Force

$runName = if ($CsvFile) { 'bulk-vmotion_{0}' -f [System.IO.Path]::GetFileNameWithoutExtension($CsvFile) } else { 'bulk-vmotion' }
$logFile = Start-BulkVMotionLog -LogDirectory $LogFolder -Name $runName -MinimumLevel $LogLevel

$crossVCenter = -not [string]::IsNullOrWhiteSpace($TargetVIServer) -and ($TargetVIServer -ne $SourceVIServer)

Write-BulkVMotionLog -Message ('Mode                     : {0}' -f $(if ($ValidateOnly) { 'VALIDATE ONLY (no VM will be migrated)' } else { 'MIGRATE' }))
Write-BulkVMotionLog -Message ('Source vCenter           : {0}' -f $SourceVIServer)
Write-BulkVMotionLog -Message ('Target vCenter           : {0}' -f $(if ($crossVCenter) { $TargetVIServer } else { "$SourceVIServer (same vCenter)" }))
Write-BulkVMotionLog -Message ('IN / MOVED / LOGS        : {0} | {1} | {2}' -f $InFolder, $MovedFolder, $LogFolder)
Write-BulkVMotionLog -Message ('Concurrent migrations    : {0}' -f $MaxConcurrentMigrations)
Write-BulkVMotionLog -Message ('Per VM timeout (minutes) : {0}' -f $MigrationTimeoutMinutes)

foreach ($required in @('VMware.VimAutomation.Core', 'VMware.VimAutomation.Vds')) {
    if (-not (Get-Module -Name $required -ListAvailable)) {
        Write-BulkVMotionLog -Level Error -Message "PowerCLI module '$required' is not installed. Install it with: Install-Module VMware.PowerCLI -Scope CurrentUser"
        Stop-BulkVMotionLog
        throw "Missing PowerCLI module '$required'."
    }
    Import-Module -Name $required -ErrorAction Stop
}

# Both vCenters have to be connected at the same time for a cross vCenter vMotion.
$powerCliConfig = @{ Scope = 'Session'; Confirm = $false; DefaultVIServerMode = 'Multiple' }
if ($IgnoreInvalidCertificate) { $powerCliConfig.InvalidCertificateAction = 'Ignore' }
Set-PowerCLIConfiguration @powerCliConfig -WarningAction SilentlyContinue | Out-Null

#endregion Module loading

#region Connect -----------------------------------------------------------------

$sourceServer = $null
$targetServer = $null
$exitCode     = 0

$summary = [ordered]@{
    'CSV files processed' = 0
    'CSV files moved'     = 0
    'VMs total'           = 0
    'VMs migrated'        = 0
    'VMs already in place' = 0
    'VMs failed'          = 0
    'VMs skipped'         = 0
}

try {
    Write-BulkVMotionLog -Message "Connecting to source vCenter '$SourceVIServer'..."
    $connectParams = @{ Server = $SourceVIServer; ErrorAction = 'Stop' }
    if ($SourceCredential) { $connectParams.Credential = $SourceCredential }
    $sourceServer = Connect-VIServer @connectParams
    Write-BulkVMotionLog -Level Success -Message "Connected to $($sourceServer.Name) (version $($sourceServer.Version))."

    if ($crossVCenter) {
        Write-BulkVMotionLog -Message "Connecting to target vCenter '$TargetVIServer'..."
        $connectParams = @{ Server = $TargetVIServer; ErrorAction = 'Stop' }
        if ($TargetCredential) { $connectParams.Credential = $TargetCredential }
        $targetServer = Connect-VIServer @connectParams
        Write-BulkVMotionLog -Level Success -Message "Connected to $($targetServer.Name) (version $($targetServer.Version))."
    }
    else {
        $targetServer = $sourceServer
    }

    #endregion Connect

    #region Build the VLAN -> port group table ----------------------------------

    $targetPortGroups = @()
    if ($TargetVDSwitch) {
        foreach ($switchName in $TargetVDSwitch) {
            $vds = Get-VDSwitch -Name $switchName -Server $targetServer -ErrorAction SilentlyContinue
            if (-not $vds) { throw "Target distributed switch '$switchName' was not found on $($targetServer.Name)." }
            $targetPortGroups += @(Get-VDPortgroup -VDSwitch $vds -Server $targetServer)
            Write-BulkVMotionLog -Message "Using target distributed switch '$($vds.Name)'."
        }
    }
    else {
        Write-BulkVMotionLog -Level Warning -Message 'No -TargetVDSwitch was supplied - every distributed port group on the target vCenter will be considered, which makes duplicate VLANs more likely.'
        $targetPortGroups = @(Get-VDPortgroup -Server $targetServer)
    }

    # IsUplink was added in newer PowerCLI releases - probe for it rather than assume it.
    $targetPortGroups = @($targetPortGroups | Where-Object {
            $uplink = $_.PSObject.Properties['IsUplink']
            -not ($uplink -and $uplink.Value)
        })
    if ($targetPortGroups.Count -eq 0) { throw 'No usable distributed port group was found on the target side.' }

    $vlanMap = Get-VlanPortGroupMap -PortGroup $targetPortGroups
    Write-VlanPortGroupMapReport -Map $vlanMap

    $exceptionMap   = Import-PortGroupExceptionMap -Path $PortGroupExceptionMap
    $sourcePgCache  = Get-SourcePortGroupCache -Server $sourceServer

    #endregion Build the VLAN -> port group table

    #region Collect the CSV files -----------------------------------------------

    if ($CsvFile) {
        if (-not (Test-Path -LiteralPath $CsvFile)) { throw "CSV file not found: $CsvFile" }
        $csvFiles = @(Get-Item -LiteralPath $CsvFile)
    }
    else {
        $csvFiles = @(Get-ChildItem -LiteralPath $InFolder -Filter '*.csv' -File | Sort-Object Name)
    }

    if ($csvFiles.Count -eq 0) {
        Write-BulkVMotionLog -Level Warning -Message "No CSV file to process in '$InFolder'."
    }
    else {
        Write-BulkVMotionLog -Message ('Found {0} CSV file(s) to process: {1}' -f $csvFiles.Count, (($csvFiles | ForEach-Object { $_.Name }) -join ', '))
    }

    #endregion Collect the CSV files

    #region Process each CSV -----------------------------------------------------

    foreach ($file in $csvFiles) {
        Write-BulkVMotionLog -Message ('-' * 100)
        Write-BulkVMotionLog -Message "Processing CSV file: $($file.FullName)"
        $summary['CSV files processed']++

        try {
            $rows = @(Import-MigrationCsv -Path $file.FullName)
        }
        catch {
            Write-BulkVMotionLog -Level Error -Message "Cannot process '$($file.Name)': $($_.Exception.Message)"
            Write-BulkVMotionLog -Level Warning -Message "'$($file.Name)' stays in the IN folder so it can be corrected and retried."
            $exitCode = 1
            continue
        }

        Write-BulkVMotionLog -Message ('{0} VM(s) listed in {1}.' -f $rows.Count, $file.Name)
        $summary['VMs total'] += $rows.Count

        $pending   = [System.Collections.Generic.Queue[object]]::new()
        $rows | ForEach-Object { $pending.Enqueue($_) }

        $running   = @()
        $completed = @()
        $aborted   = $false

        while ($pending.Count -gt 0 -or $running.Count -gt 0) {

            while (-not $aborted -and $running.Count -lt $MaxConcurrentMigrations -and $pending.Count -gt 0) {
                $row = $pending.Dequeue()
                Write-BulkVMotionLog -Message ('-' * 60)
                Write-BulkVMotionLog -VMName $row.VMName -Message "Preparing migration (CSV line $($row.CsvLine))."

                try {
                    $plan = New-VMMigrationPlan -Row $row -SourceServer $sourceServer -TargetServer $targetServer `
                        -VlanMap $vlanMap -TargetPortGroup $targetPortGroups -PortGroupCache $sourcePgCache `
                        -ExceptionMap $exceptionMap -DefaultCluster $DefaultTargetCluster `
                        -DefaultDatastore $DefaultTargetDatastore -DefaultFolder $DefaultTargetFolder `
                        -DatastoreReserveGB $DatastoreReserveGB -CrossVCenter:$crossVCenter
                }
                catch {
                    $plan = [pscustomobject]@{
                        VMName = $row.VMName; CsvLine = $row.CsvLine; VM = $null
                        SourceCluster = ''; SourceHost = ''; TargetCluster = ''; TargetHost = $null
                        Datastore = $null; DatastoreName = ''; Folder = $null; FolderName = ''
                        Adapters = @(); PortGroups = @(); NetworkDetails = @()
                        Ready = $false; Errors = @($_.Exception.Message)
                    }
                }

                Write-MigrationPlanReport -Plan $plan

                if (-not $plan.Ready) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Failed' -Message (($plan.Errors) -join ' / ')
                    Write-BulkVMotionLog -Level Error -VMName $row.VMName -Message 'VM skipped - the plan could not be validated.'
                    if ($StopOnError) { $aborted = $true }
                    continue
                }

                if ($plan.AlreadyInPlace) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'AlreadyDone' -Message 'Already in the target cluster, on the target storage and on the target port group(s) - nothing to do.'
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message 'Already migrated by an earlier run - nothing to do.'
                    continue
                }

                if ($ValidateOnly) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Skipped' -Message 'Validation only - the VM was not migrated.'
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message 'Plan is valid.'
                    continue
                }

                if (-not $PSCmdlet.ShouldProcess($row.VMName, "vMotion to $($plan.TargetHost.Name)")) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Skipped' -Message 'Skipped by -WhatIf/-Confirm.'
                    continue
                }

                try {
                    $task = Start-VMMigrationTask -Plan $plan -VMotionPriority $VMotionPriority -DiskStorageFormat $DiskStorageFormat

                    if ($null -eq $task) {
                        # Port groups only - Start-VMMigrationTask did it synchronously.
                        $tracker = New-MigrationTracker -Plan $plan -Status 'Success' -Message 'Network adapter(s) reconnected to the target port group(s); no vMotion was needed.'
                        $tracker.End = Get-Date
                        $completed += $tracker
                        Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message 'Network adapter(s) reconnected to the target port group(s) - no vMotion was needed.'
                    }
                    else {
                        $running += New-MigrationTracker -Plan $plan -Task $task
                        Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message "Migration started (task $($task.Id))."
                    }
                }
                catch {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Failed' -Message $_.Exception.Message
                    Write-BulkVMotionLog -Level Error -VMName $row.VMName -Message "Could not start the migration: $($_.Exception.Message)"
                    if ($StopOnError) { $aborted = $true }
                }
            }

            if ($running.Count -gt 0) {
                Start-Sleep -Seconds $PollIntervalSeconds
                $tracked   = $running
                $running   = @(Wait-VMMigrationTask -Tracker $tracked -TimeoutMinutes $MigrationTimeoutMinutes)
                $finished  = @($tracked | Where-Object { $_.Status -ne 'Running' })
                $completed += $finished

                if ($StopOnError -and @($finished | Where-Object { $_.Status -ne 'Success' }).Count -gt 0) {
                    $aborted = $true
                }
            }

            if ($aborted -and $pending.Count -gt 0 -and $running.Count -eq 0) {
                Write-BulkVMotionLog -Level Warning -Message "-StopOnError is set and a VM failed: the remaining $($pending.Count) VM(s) in this file will not be migrated."
                while ($pending.Count -gt 0) {
                    $row  = $pending.Dequeue()
                    $stub = [pscustomobject]@{
                        VMName = $row.VMName; CsvLine = $row.CsvLine; VM = $null
                        SourceCluster = ''; SourceHost = ''; TargetCluster = ''; TargetHost = $null
                        Datastore = $null; DatastoreName = ''; Folder = $null; FolderName = ''
                        Adapters = @(); PortGroups = @(); NetworkDetails = @()
                        Ready = $false; Errors = @()
                    }
                    $completed += New-MigrationTracker -Plan $stub -Status 'Skipped' -Message 'Not attempted - the run was stopped by -StopOnError.'
                }
            }
        }

        #region Result of this file ---------------------------------------------

        $succeeded   = @($completed | Where-Object { $_.Status -eq 'Success' })
        $failed      = @($completed | Where-Object { $_.Status -in @('Failed', 'TimedOut') })
        $skipped     = @($completed | Where-Object { $_.Status -eq 'Skipped' })
        $alreadyDone = @($completed | Where-Object { $_.Status -eq 'AlreadyDone' })

        $summary['VMs migrated']       += $succeeded.Count
        $summary['VMs failed']         += $failed.Count
        $summary['VMs skipped']        += $skipped.Count
        $summary['VMs already in place'] += $alreadyDone.Count

        if ($completed.Count -gt 0) {
            $resultPath = Join-Path $LogFolder ('{0}_result_{1}.csv' -f $file.BaseName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $completed | ConvertTo-MigrationResult | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
            Write-BulkVMotionLog -Message "Per VM result written to $resultPath"
        }

        Write-BulkVMotionLog -Message ('Result for {0}: {1} migrated, {2} already in place, {3} failed, {4} skipped.' -f $file.Name, $succeeded.Count, $alreadyDone.Count, $failed.Count, $skipped.Count)
        foreach ($item in $failed) {
            Write-BulkVMotionLog -Level Error -VMName $item.VMName -Message ('{0}: {1}' -f $item.Status, $item.Message)
        }

        if ($failed.Count -gt 0) { $exitCode = 1 }

        # Move the CSV only when the whole file has been dealt with.
        $shouldMove = switch ($MoveCsvWhen) {
            'Always'     { $true }
            'Never'      { $false }
            'AllSuccess' { ($failed.Count -eq 0 -and $skipped.Count -eq 0 -and ($succeeded.Count + $alreadyDone.Count) -gt 0) }
        }

        if ($ValidateOnly) {
            Write-BulkVMotionLog -Message "Validation only - '$($file.Name)' stays in the IN folder."
        }
        elseif ($shouldMove) {
            $movedTo = Move-ProcessedCsv -Path $file.FullName -Destination $MovedFolder
            $summary['CSV files moved']++
            Write-BulkVMotionLog -Level Success -Message "All VMs in '$($file.Name)' have been migrated - the file was moved to $movedTo"
        }
        else {
            Write-BulkVMotionLog -Level Warning -Message "'$($file.Name)' stays in the IN folder ($($failed.Count) failed, $($skipped.Count) skipped). Correct the failing rows and run again."
        }

        #endregion Result of this file
    }

    #endregion Process each CSV
}
catch {
    $exitCode = 2
    Write-BulkVMotionLog -Level Error -Message "The run stopped: $($_.Exception.Message)"
    Write-BulkVMotionLog -Level Debug -Message ($_.ScriptStackTrace)
}
finally {
    foreach ($server in @($sourceServer, $targetServer) | Where-Object { $_ } | Sort-Object -Property Name -Unique) {
        try {
            Disconnect-VIServer -Server $server -Confirm:$false -ErrorAction SilentlyContinue
            Write-BulkVMotionLog -Message "Disconnected from $($server.Name)."
        }
        catch {
            Write-BulkVMotionLog -Level Warning -Message "Could not cleanly disconnect from $($server.Name): $($_.Exception.Message)"
        }
    }

    $summary['Log file'] = $logFile
    Stop-BulkVMotionLog -Summary $summary
}

exit $exitCode
