<#
.SYNOPSIS
    Phase driven bulk migration of VMs listed in CSV files, from one vSphere cluster
    to another, including the VDS change where the target port group is found by VLAN ID.

.DESCRIPTION
    The migration runs in three phases, weeks or months apart. Each CSV file records
    the phase its VMs have completed and is archived into the matching Phase folder,
    so the folder a file sits in tells you where that wave has got to:

      Phase 1  vMotion from the old cluster to the new one and remap every network
               adapter onto the new VDS by VLAN ID. Storage is not touched.
      Phase 2  Storage vMotion onto the new datastore. The VMs stay on their host and
               keep their networking.
      Phase 3  Cross vCenter vMotion to the new vCenter and cluster. The datastore is
               the same shared volume, so no data moves, and the port groups are
               remapped onto the new vCenter's VDS by VLAN ID.

    A run processes the CSV files in IN that are due for the run's phase. When every VM
    in a file has completed the phase, the file is updated with the result and moved to
    Phase1, Phase2 or Phase3. A file that still has VMs outstanding stays in IN: fix the
    rows that failed and run it again, and the VMs that already completed are skipped.

    Everything the run does is written to the console and to a log file in LOGS.

.PARAMETER Phase
    The phase this run is. When it disagrees with what a CSV file says it is due for,
    that file is refused rather than migrated. Omit it to take the phase from the files.

.PARAMETER SourceVIServer
    The vCenter the VMs are in now. For phases 1 and 2 this is the only vCenter involved.

.PARAMETER TargetVIServer
    The new vCenter. Phase 3 only.

.PARAMETER TargetVDSwitch
    The distributed switch to map the port groups onto in this run's phase: the new VDS
    in phase 1, the new vCenter's VDS in phase 3. Not used in phase 2.

.PARAMETER ValidateOnly
    Resolve and report everything, but migrate nothing and leave the files alone.
    Run this first - it is the dry run.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -Phase 1 -SourceVIServer vc.corp.local -TargetVDSwitch 'VDS-NEW' `
        -DefaultTargetCluster 'CL-NEW-01' -ValidateOnly

    Dry run of the first wave: shows the VLAN table, the resolved port group for every
    adapter and any problem, without touching a VM.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -Phase 2 -SourceVIServer vc.corp.local -DefaultTargetDatastore 'DSC-NEW-PROD'

    The storage wave, weeks later: Storage vMotion only, no host or network change.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -Phase 3 -SourceVIServer vc.corp.local -TargetVIServer vc-new.corp.local `
        -TargetVDSwitch 'VDS-VC2' -DefaultTargetCluster 'CL-FINAL-01'

    The cross vCenter wave: same shared datastore, new cluster, port groups remapped
    onto the new vCenter's VDS.

.NOTES
    Requires PowerCLI 12.0 or later (VMware.VimAutomation.Core / VMware.VimAutomation.Vds).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 3)]
    [int]$Phase,

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

    # Phase1, Phase2 and Phase3 are created under this folder.
    [string]$ArchiveRoot,

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

# Values from the JSON config are applied only to parameters that were not passed on
# the command line, so an explicit argument always wins.
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
if (-not $ArchiveRoot) { $ArchiveRoot = $scriptRoot }
if (-not $LogFolder)   { $LogFolder   = Join-Path $scriptRoot 'LOGS' }
if (-not $PortGroupExceptionMap) {
    $candidate = Join-Path (Join-Path $scriptRoot 'config') 'portgroup-exceptions.csv'
    if (Test-Path -LiteralPath $candidate) { $PortGroupExceptionMap = $candidate }
}

foreach ($folder in @($InFolder, $ArchiveRoot, $LogFolder)) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
}

#endregion Configuration file

#region Start up ----------------------------------------------------------------

Import-Module (Join-Path (Join-Path (Join-Path $scriptRoot 'Modules') 'BulkVMotion') 'BulkVMotion.psd1') -Force

$runName = if ($CsvFile) { 'bulk-vmotion_{0}' -f [System.IO.Path]::GetFileNameWithoutExtension($CsvFile) } else { 'bulk-vmotion' }
$logFile = Start-BulkVMotionLog -LogDirectory $LogFolder -Name $runName -MinimumLevel $LogLevel

Write-BulkVMotionLog -Message ('Mode                     : {0}' -f $(if ($ValidateOnly) { 'VALIDATE ONLY (no VM will be migrated)' } else { 'MIGRATE' }))
Write-BulkVMotionLog -Message ('Source vCenter           : {0}' -f $SourceVIServer)
Write-BulkVMotionLog -Message ('IN / archive / LOGS      : {0} | {1} | {2}' -f $InFolder, $ArchiveRoot, $LogFolder)
Write-BulkVMotionLog -Message ('Concurrent migrations    : {0}' -f $MaxConcurrentMigrations)
Write-BulkVMotionLog -Message ('Per VM timeout (minutes) : {0}' -f $MigrationTimeoutMinutes)

$sourceServer = $null
$targetServer = $null
$exitCode     = 0
$runPhase     = 0

$summary = [ordered]@{
    'CSV files processed'   = 0
    'CSV files archived'    = 0
    'VMs total'             = 0
    'VMs migrated'          = 0
    'VMs already in place'  = 0
    'VMs failed'            = 0
    'VMs skipped'           = 0
}

try {
    #region Read the CSV files and settle the phase ------------------------------

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

    # Reading the files first is what lets a file declare its own phase.
    $work = @()
    foreach ($file in $csvFiles) {
        try {
            $rows = @(Import-MigrationCsv -Path $file.FullName)
            $phaseInfo = Get-CsvNextPhase -Row $rows -Assert $Phase
            $work += [pscustomobject]@{ File = $file; Rows = $rows; PhaseInfo = $phaseInfo }
        }
        catch {
            Write-BulkVMotionLog -Level Error -Message "Cannot process '$($file.Name)': $($_.Exception.Message)"
            Write-BulkVMotionLog -Level Warning -Message "'$($file.Name)' stays in the IN folder so it can be corrected and retried."
            $summary['CSV files processed']++
            $exitCode = 1
        }
    }

    if ($work.Count -gt 0) {
        # One run is one phase. Without -Phase the first file decides.
        $runPhase = if ($Phase -gt 0) { $Phase } else { @($work | Where-Object { -not $_.PhaseInfo.IsComplete } | Select-Object -First 1 -ExpandProperty PhaseInfo | ForEach-Object { $_.Phase }) }
        if (-not $runPhase) { $runPhase = 3 }

        Write-BulkVMotionLog -Message ('Phase                    : {0}{1}' -f $runPhase, $(if ($Phase -gt 0) { ' (from -Phase)' } else { ' (taken from the CSV files)' }))

        $phaseDescription = switch ($runPhase) {
            1 { 'cluster change and VDS/port group remap, storage untouched' }
            2 { 'Storage vMotion only, host and networking untouched' }
            3 { 'cross vCenter vMotion, same shared datastore, port groups remapped' }
        }
        Write-BulkVMotionLog -Message ('Phase means              : {0}' -f $phaseDescription)

        if ($runPhase -eq 3) {
            Write-BulkVMotionLog -Message ('Target vCenter           : {0}' -f $TargetVIServer)
            if ([string]::IsNullOrWhiteSpace($TargetVIServer)) {
                throw 'Phase 3 is the cross vCenter move, so -TargetVIServer is required.'
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($TargetVIServer) -and $TargetVIServer -ne $SourceVIServer) {
            throw "Phase $runPhase runs inside one vCenter, but -TargetVIServer '$TargetVIServer' was supplied. Only phase 3 crosses vCenters."
        }

        if ($runPhase -ne 2 -and -not $TargetVDSwitch) {
            Write-BulkVMotionLog -Level Warning -Message 'No -TargetVDSwitch was supplied - every distributed port group on the target vCenter will be considered. With the old and the new VDS in the same vCenter that makes duplicate VLANs almost certain.'
        }
    }

    #endregion Read the CSV files and settle the phase

    #region PowerCLI and connections --------------------------------------------

    foreach ($required in @('VMware.VimAutomation.Core', 'VMware.VimAutomation.Vds')) {
        if (-not (Get-Module -Name $required -ListAvailable)) {
            throw "PowerCLI module '$required' is not installed. Install it with: Install-Module VMware.PowerCLI -Scope CurrentUser"
        }
        Import-Module -Name $required -ErrorAction Stop
    }

    # Both vCenters have to be connected at once for a cross vCenter vMotion.
    $powerCliConfig = @{ Scope = 'Session'; Confirm = $false; DefaultVIServerMode = 'Multiple' }
    if ($IgnoreInvalidCertificate) { $powerCliConfig.InvalidCertificateAction = 'Ignore' }
    Set-PowerCLIConfiguration @powerCliConfig -WarningAction SilentlyContinue | Out-Null

    Write-BulkVMotionLog -Message "Connecting to source vCenter '$SourceVIServer'..."
    $connectParams = @{ Server = $SourceVIServer; ErrorAction = 'Stop' }
    if ($SourceCredential) { $connectParams.Credential = $SourceCredential }
    $sourceServer = Connect-VIServer @connectParams
    Write-BulkVMotionLog -Level Success -Message "Connected to $($sourceServer.Name) (version $($sourceServer.Version))."

    if ($runPhase -eq 3) {
        Write-BulkVMotionLog -Message "Connecting to target vCenter '$TargetVIServer'..."
        $connectParams = @{ Server = $TargetVIServer; ErrorAction = 'Stop' }
        if ($TargetCredential) { $connectParams.Credential = $TargetCredential }
        $targetServer = Connect-VIServer @connectParams
        Write-BulkVMotionLog -Level Success -Message "Connected to $($targetServer.Name) (version $($targetServer.Version))."
    }
    else {
        $targetServer = $sourceServer
    }

    #endregion PowerCLI and connections

    #region The VLAN table ------------------------------------------------------

    $vlanMap          = @{}
    $targetPortGroups = @()
    $exceptionMap     = @{}
    $sourcePgCache    = @{}

    if ($runPhase -ne 2 -and $work.Count -gt 0) {
        if ($TargetVDSwitch) {
            foreach ($switchName in $TargetVDSwitch) {
                $vds = Get-VDSwitch -Name $switchName -Server $targetServer -ErrorAction SilentlyContinue
                if (-not $vds) { throw "Target distributed switch '$switchName' was not found on $($targetServer.Name)." }
                $targetPortGroups += @(Get-VDPortgroup -VDSwitch $vds -Server $targetServer)
                Write-BulkVMotionLog -Message "Using target distributed switch '$($vds.Name)'."
            }
        }
        else {
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

        $exceptionMap  = Import-PortGroupExceptionMap -Path $PortGroupExceptionMap
        $sourcePgCache = Get-SourcePortGroupCache -Server $sourceServer
    }

    #endregion The VLAN table

    #region Process each CSV -----------------------------------------------------

    foreach ($item in $work) {
        $file      = $item.File
        $rows      = $item.Rows
        $phaseInfo = $item.PhaseInfo

        Write-BulkVMotionLog -Message ('-' * 100)
        Write-BulkVMotionLog -Message "Processing CSV file: $($file.FullName)"
        $summary['CSV files processed']++

        if ($phaseInfo.Reason) {
            Write-BulkVMotionLog -Level Error -Message "'$($file.Name)': $($phaseInfo.Reason)"
            $exitCode = 1
            continue
        }

        if ($phaseInfo.IsComplete) {
            Write-BulkVMotionLog -Level Success -Message "'$($file.Name)': every VM has completed phase 3 - the wave is finished."
            if (-not $ValidateOnly) {
                $movedTo = Move-ProcessedCsv -Path $file.FullName -Destination (Join-Path $ArchiveRoot 'Phase3')
                $summary['CSV files archived']++
                Write-BulkVMotionLog -Level Success -Message "Archived to $movedTo"
            }
            continue
        }

        if ($phaseInfo.Phase -ne $runPhase) {
            Write-BulkVMotionLog -Level Warning -Message "'$($file.Name)' is due for phase $($phaseInfo.Phase) but this run is phase $runPhase - the file was left untouched in IN."
            continue
        }

        Write-BulkVMotionLog -Message ('{0} VM(s) listed in {1}, running phase {2}.' -f $rows.Count, $file.Name, $runPhase)
        $summary['VMs total'] += $rows.Count

        $pending = [System.Collections.Generic.Queue[object]]::new()
        $rows | ForEach-Object { $pending.Enqueue($_) }

        $running   = @()
        $completed = @()
        $aborted   = $false

        while ($pending.Count -gt 0 -or $running.Count -gt 0) {

            while (-not $aborted -and $running.Count -lt $MaxConcurrentMigrations -and $pending.Count -gt 0) {
                $row = $pending.Dequeue()

                # A row that is already past this phase is not looked at again.
                if ([int]$row.PhaseCompleted -ge $runPhase) {
                    $stub = [pscustomobject]@{
                        VMName = $row.VMName; CsvLine = $row.CsvLine; Phase = $runPhase; VM = $null
                        SourceCluster = ''; SourceHost = ''; TargetCluster = ''; TargetHost = $null
                        Datastore = $null; DatastoreName = ''; Folder = $null; FolderName = ''
                        Adapters = @(); PortGroups = @(); NetworkDetails = @()
                        ChangesCompute = $false; ChangesStorage = $false; ChangesNetwork = $false
                        NetworkOnly = $false; StorageOnly = $false; AlreadyInPlace = $true
                        Ready = $true; Errors = @()
                    }
                    $completed += New-MigrationTracker -Plan $stub -Status 'AlreadyDone' -Message "Completed phase $($row.PhaseCompleted) in an earlier run."
                    Write-BulkVMotionLog -VMName $row.VMName -Message "Already completed phase $runPhase in an earlier run - skipped."
                    continue
                }

                Write-BulkVMotionLog -Message ('-' * 60)
                Write-BulkVMotionLog -VMName $row.VMName -Message "Preparing phase $runPhase (CSV line $($row.CsvLine))."

                try {
                    $plan = New-VMMigrationPlan -Row $row -Phase $runPhase -SourceServer $sourceServer -TargetServer $targetServer `
                        -VlanMap $vlanMap -TargetPortGroup $targetPortGroups -PortGroupCache $sourcePgCache `
                        -ExceptionMap $exceptionMap -DefaultCluster $DefaultTargetCluster `
                        -DefaultDatastore $DefaultTargetDatastore -DefaultFolder $DefaultTargetFolder `
                        -DatastoreReserveGB $DatastoreReserveGB
                }
                catch {
                    $plan = [pscustomobject]@{
                        VMName = $row.VMName; CsvLine = $row.CsvLine; Phase = $runPhase; VM = $null
                        SourceCluster = ''; SourceHost = ''; TargetCluster = ''; TargetHost = $null
                        Datastore = $null; DatastoreName = ''; Folder = $null; FolderName = ''
                        Adapters = @(); PortGroups = @(); NetworkDetails = @()
                        ChangesCompute = $false; ChangesStorage = $false; ChangesNetwork = $false
                        NetworkOnly = $false; StorageOnly = $false; AlreadyInPlace = $false
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
                    $completed += New-MigrationTracker -Plan $plan -Status 'AlreadyDone' -Message "Nothing to do for phase $runPhase - the VM is already where this phase would put it."
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message "Nothing to do for phase $runPhase."
                    continue
                }

                if ($ValidateOnly) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Skipped' -Message 'Validation only - the VM was not migrated.'
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message 'Plan is valid.'
                    continue
                }

                if (-not $PSCmdlet.ShouldProcess($row.VMName, "phase $runPhase migration")) {
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
                        VMName = $row.VMName; CsvLine = $row.CsvLine; Phase = $runPhase; VM = $null
                        SourceCluster = ''; SourceHost = ''; TargetCluster = ''; TargetHost = $null
                        Datastore = $null; DatastoreName = ''; Folder = $null; FolderName = ''
                        Adapters = @(); PortGroups = @(); NetworkDetails = @()
                        ChangesCompute = $false; ChangesStorage = $false; ChangesNetwork = $false
                        NetworkOnly = $false; StorageOnly = $false; AlreadyInPlace = $false
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

        $summary['VMs migrated']         += $succeeded.Count
        $summary['VMs failed']           += $failed.Count
        $summary['VMs skipped']          += $skipped.Count
        $summary['VMs already in place'] += $alreadyDone.Count

        if ($completed.Count -gt 0) {
            $resultPath = Join-Path $LogFolder ('{0}_phase{1}_result_{2}.csv' -f $file.BaseName, $runPhase, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $completed | ConvertTo-MigrationResult | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
            Write-BulkVMotionLog -Message "Per VM result written to $resultPath"
        }

        Write-BulkVMotionLog -Message ('Result for {0} phase {1}: {2} migrated, {3} already done, {4} failed, {5} skipped.' -f $file.Name, $runPhase, $succeeded.Count, $alreadyDone.Count, $failed.Count, $skipped.Count)
        foreach ($entry in $failed) {
            Write-BulkVMotionLog -Level Error -VMName $entry.VMName -Message ('{0}: {1}' -f $entry.Status, $entry.Message)
        }

        if ($failed.Count -gt 0) { $exitCode = 1 }

        #endregion Result of this file

        #region Record the phase in the file and archive it ----------------------

        if ($ValidateOnly) {
            Write-BulkVMotionLog -Message "Validation only - '$($file.Name)' stays in the IN folder unchanged."
            continue
        }

        # Every VM that has this phase behind it now gets it written into the file, so a
        # re-run knows what is left and the archived file is the record of the wave.
        $stamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $updates = @()
        foreach ($entry in @($succeeded + $alreadyDone)) {
            $plan = $entry.Plan
            $updates += [pscustomobject]@{
                CsvLine         = $entry.CsvLine
                PhaseCompleted  = $runPhase
                CompletedAt     = $stamp
                ResultVIServer  = $targetServer.Name
                ResultCluster   = $plan.TargetCluster
                ResultHost      = if ($plan.TargetHost) { $plan.TargetHost.Name } else { '' }
                ResultDatastore = $plan.DatastoreName
                ResultPortGroup = (@($plan.PortGroups | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ' + '
            }
        }

        if ($updates.Count -gt 0) {
            Update-MigrationCsv -Path $file.FullName -Update $updates
            Write-BulkVMotionLog -Message ('Recorded phase {0} for {1} VM(s) in {2}.' -f $runPhase, $updates.Count, $file.Name)
        }

        $allDone = ($failed.Count -eq 0 -and $skipped.Count -eq 0 -and ($succeeded.Count + $alreadyDone.Count) -gt 0)
        $shouldMove = switch ($MoveCsvWhen) {
            'Always'     { $true }
            'Never'      { $false }
            'AllSuccess' { $allDone }
        }

        if ($shouldMove) {
            $movedTo = Move-ProcessedCsv -Path $file.FullName -Destination (Join-Path $ArchiveRoot ('Phase{0}' -f $runPhase))
            $summary['CSV files archived']++
            Write-BulkVMotionLog -Level Success -Message "Every VM in '$($file.Name)' has completed phase $runPhase - the file was moved to $movedTo"
            if ($runPhase -lt 3) {
                Write-BulkVMotionLog -Message "When the next wave is due, move that file back into IN and run phase $($runPhase + 1)."
            }
        }
        else {
            Write-BulkVMotionLog -Level Warning -Message "'$($file.Name)' stays in the IN folder ($($failed.Count) failed, $($skipped.Count) skipped). Correct the failing rows and run phase $runPhase again - the VMs that are done will be skipped."
        }

        #endregion Record the phase in the file and archive it
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

    if ($runPhase -gt 0) { $summary['Phase'] = $runPhase }
    $summary['Log file'] = $logFile
    Stop-BulkVMotionLog -Summary $summary
}

exit $exitCode
