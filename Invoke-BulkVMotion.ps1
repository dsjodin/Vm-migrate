<#
.SYNOPSIS
    Phase driven bulk migration of VMs listed in CSV waves, including the VDS change
    where the target port group is found by VLAN ID.

.DESCRIPTION
    The migration runs in three phases, weeks or months apart. Each CSV file is a wave
    that records the phase its VMs have completed and is archived into the matching
    Phase folder, so the folder a file sits in tells you where that wave has got to:

      Phase 1  vMotion from the old cluster to the new one and remap every network
               adapter onto the new VDS by VLAN ID. Storage is not touched.
      Phase 2  Storage vMotion onto the new datastore. The VMs stay on their host and
               keep their networking.
      Phase 3  Cross vCenter vMotion to the new vCenter and cluster. The datastore is
               the same shared volume, so no data moves, and the port groups are
               remapped onto the new vCenter's VDS by VLAN ID.

    A run migrates one wave. The waves due for the phase are listed and you pick one;
    it moves into Running while it is yours, so a colleague on the same mgmt server
    cannot start the same wave. When every VM in it has completed the phase the file is
    updated and moved to Phase1, Phase2 or Phase3. A wave with VMs still outstanding
    goes back to IN: fix the rows that failed and run it again, and the VMs that are
    already done are skipped.

    Concurrency follows vSphere's own resource cost model rather than a flat count, so
    a host is never pushed past 8 migration cost (8 vMotions, or 2 Storage vMotions) and
    a datastore never past 128 (8 Storage vMotions). Migrations other engineers have
    started are counted too.

.PARAMETER Phase
    The phase this run is. Only waves due for it can be picked. Omit it to be shown
    every wave and take the phase from the one you choose.

.PARAMETER SourceVIServer
    The vCenter the VMs are in now. For phases 1 and 2 this is the only one involved.

.PARAMETER TargetVIServer
    The new vCenter. Phase 3 only.

.PARAMETER TargetVDSwitch
    Fallback distributed switch for VMs whose row leaves Phase1VDS / Phase3VDS empty.

.PARAMETER ValidateOnly
    Resolve everything and write the port groups it worked out back into the CSV, but
    migrate nothing and leave the phase untouched. Run this first, check the port
    groups, then run for real.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -Phase 1 -SourceVIServer vc.corp.local -ValidateOnly

    Lists the waves due for phase 1, and for the one you pick fills in the port group
    it would use for every NIC without touching a VM.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -Phase 2 -SourceVIServer vc.corp.local

    The storage wave: Storage vMotion only, thin provisioned, two per host.

.EXAMPLE
    .\Invoke-BulkVMotion.ps1 -Phase 3 -SourceVIServer vc.corp.local -TargetVIServer vc-new.corp.local

    The cross vCenter wave: same shared datastore, new cluster, port groups remapped
    onto the new vCenter's VDS.

.NOTES
    Requires PowerCLI 12.0 or later. Store your vCenter credentials once with
    .\Save-MigrationCredential.ps1 -VIServer <vcenter>.
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

    [string]$InFolder,

    [string]$RunningFolder,

    # Phase1, Phase2 and Phase3 are created under this folder.
    [string]$ArchiveRoot,

    [string]$LogFolder,

    # Run this wave instead of showing the picker.
    [string]$CsvFile,

    [string]$PortGroupExceptionMap,

    # 8 for a 10GigE vMotion network or faster, 4 for 1GigE.
    [ValidateRange(1, 8)]
    [int]$VMotionNetworkLimit = 8,

    # Do not count migrations other engineers have started against the budget.
    [switch]$IgnoreExternalTasks,

    [ValidateRange(1, 1440)]
    [int]$MigrationTimeoutMinutes = 120,

    [ValidateRange(5, 600)]
    [int]$PollIntervalSeconds = 15,

    [ValidateSet('Low', 'Standard', 'High')]
    [string]$VMotionPriority = 'High',

    [ValidateSet('Thin', 'Thick', 'EagerZeroedThick', 'AsDefined')]
    [string]$DiskStorageFormat = 'Thin',

    # Free space that must remain on the target datastore after the VM lands there.
    [double]$DatastoreReserveGB = 100,

    # Stop starting new migrations as soon as one VM fails.
    [switch]$StopOnError,

    [switch]$ValidateOnly,

    # Take a wave another engineer's run still claims. Be sure their run is really gone.
    [switch]$TakeOver,

    # Never prompt: fail instead of showing the picker.
    [switch]$NonInteractive,

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

# A target vCenter named on the command line for a phase that does not cross vCenters is
# a mistake worth stopping for. The same value in the config is not: the config describes
# the whole project, phase 3 included, and is read by every run.
$targetVIServerFromCommandLine = $PSBoundParameters.ContainsKey('TargetVIServer')

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

if (-not $InFolder)      { $InFolder      = Join-Path $scriptRoot 'IN' }
if (-not $ArchiveRoot)   { $ArchiveRoot   = $scriptRoot }
if (-not $RunningFolder) { $RunningFolder = Join-Path $ArchiveRoot 'Running' }
if (-not $LogFolder)     { $LogFolder     = Join-Path $scriptRoot 'LOGS' }
if (-not $PortGroupExceptionMap) {
    $candidate = Join-Path (Join-Path $scriptRoot 'config') 'portgroup-exceptions.csv'
    if (Test-Path -LiteralPath $candidate) { $PortGroupExceptionMap = $candidate }
}

foreach ($folder in @($InFolder, $RunningFolder, $ArchiveRoot, $LogFolder)) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
}

#endregion Configuration file

#region Start up ----------------------------------------------------------------

Import-Module (Join-Path (Join-Path (Join-Path $scriptRoot 'Modules') 'BulkVMotion') 'BulkVMotion.psd1') -Force

# Several engineers share the mgmt server, so the log is named after whoever ran it.
$engineer = if ($env:USERNAME) { $env:USERNAME } else { 'unknown' }
$logFile  = Start-BulkVMotionLog -LogDirectory $LogFolder -Name ('bulk-vmotion_{0}' -f $engineer) -MinimumLevel $LogLevel

function Get-WaveHomeFolder {
    <#
        A wave lives in the folder matching the lowest phase all of its rows have
        completed: IN while any VM still has phase 1 to do, Phase1 once every VM has
        finished phase 1, and so on. Derived from the file itself, so nobody has to move
        a wave between phases and one put in the wrong place by hand is corrected by the
        next run.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $lowest = (Get-CsvNextPhase -Row @(Import-MigrationCsv -Path $Path)).Phase - 1
    }
    catch {
        # Cannot be read, so it needs a human: IN is where they will look.
        return $InFolder
    }

    if ($lowest -le 0) { return $InFolder }
    return (Join-Path $ArchiveRoot ('Phase{0}' -f [math]::Min($lowest, 3)))
}

$sourceServer = $null
$targetServer = $null
$exitCode     = 0
$runPhase     = 0
$wave         = $null
$wavePath     = $null
$waveDestination = $null

$summary = [ordered]@{
    'Wave'                 = ''
    'VMs total'            = 0
    'VMs migrated'         = 0
    'VMs already in place' = 0
    'VMs failed'           = 0
    'VMs skipped'          = 0
}

try {
    Write-BulkVMotionLog -Message ('Mode                     : {0}' -f $(if ($ValidateOnly) { 'VALIDATE ONLY (nothing will be migrated)' } else { 'MIGRATE' }))
    Write-BulkVMotionLog -Message ('Engineer                 : {0}\{1} on {2}' -f $env:USERDOMAIN, $engineer, $env:COMPUTERNAME)
    Write-BulkVMotionLog -Message ('Source vCenter           : {0}' -f $SourceVIServer)
    Write-BulkVMotionLog -Message ('IN / Running / archive   : {0} | {1} | {2}' -f $InFolder, $RunningFolder, $ArchiveRoot)

    #region Choose the wave ------------------------------------------------------

    if ($CsvFile) {
        if (-not (Test-Path -LiteralPath $CsvFile)) { throw "CSV file not found: $CsvFile" }
        $file = Get-Item -LiteralPath $CsvFile
        $rows = @(Import-MigrationCsv -Path $file.FullName)
        $phaseInfo = Get-CsvNextPhase -Row $rows -Assert $Phase
        if ($phaseInfo.Reason) { throw $phaseInfo.Reason }
        if ($phaseInfo.IsComplete) { throw "Every VM in '$($file.Name)' has completed phase 3." }

        $wave = [pscustomobject]@{
            Name = $file.Name; Path = $file.FullName; Rows = $rows; VMCount = $rows.Count
            NextPhase = $phaseInfo.Phase; PhaseInfo = $phaseInfo
            State = 'Ready'; StateDetail = ''; Marker = $null; Selectable = $true; InRunning = $false
        }
    }
    else {
        $available = @(Get-AvailableWave -InFolder $InFolder -RunningFolder $RunningFolder -ArchiveRoot $ArchiveRoot -Phase $Phase)

        if ($TakeOver) {
            # Only do this when you know the other run is really gone.
            foreach ($busy in @($available | Where-Object { $_.State -eq 'Busy' })) {
                $busy.Selectable  = $true
                $busy.StateDetail = '{0} - TAKING OVER' -f $busy.StateDetail
            }
        }

        if ($NonInteractive) {
            $ready = @($available | Where-Object { $_.Selectable })
            if ($ready.Count -ne 1) {
                throw "-NonInteractive needs exactly one runnable wave, but there are $($ready.Count). Use -CsvFile to name one."
            }
            $wave = $ready[0]
            Write-BulkVMotionLog -Message "Running the only wave available: $($wave.Name)"
        }
        else {
            $wave = Show-WavePicker -Wave $available -Phase $Phase
        }
    }

    if (-not $wave) {
        Write-BulkVMotionLog -Message 'No wave was chosen - nothing to do.'
        return
    }

    $runPhase = $wave.NextPhase
    $summary['Wave'] = $wave.Name

    Write-BulkVMotionLog -Message ('Wave                     : {0} ({1} VM(s))' -f $wave.Name, $wave.VMCount)
    Write-BulkVMotionLog -Message ('Phase                    : {0}' -f $runPhase)

    $phaseDescription = switch ($runPhase) {
        1 { 'cluster change and VDS/port group remap, storage untouched' }
        2 { 'Storage vMotion only, host and networking untouched' }
        3 { 'cross vCenter vMotion, same shared datastore, port groups remapped' }
    }
    Write-BulkVMotionLog -Message ('Phase means              : {0}' -f $phaseDescription)

    if ($wave.State -eq 'Interrupted') {
        Write-BulkVMotionLog -Level Warning -Message "Resuming a wave that was interrupted: $($wave.StateDetail). VMs that got through will be skipped."
    }

    if ($runPhase -eq 3) {
        if ([string]::IsNullOrWhiteSpace($TargetVIServer)) {
            throw 'Phase 3 is the cross vCenter move, so -TargetVIServer is required.'
        }
        Write-BulkVMotionLog -Message ('Target vCenter           : {0}' -f $TargetVIServer)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TargetVIServer) -and $TargetVIServer -ne $SourceVIServer) {
        if ($targetVIServerFromCommandLine) {
            throw "Phase $runPhase runs inside one vCenter, but -TargetVIServer '$TargetVIServer' was supplied. Only phase 3 crosses vCenters."
        }
        Write-BulkVMotionLog -Level Debug -Message "Ignoring the target vCenter from the configuration file: phase $runPhase runs inside $SourceVIServer."
        $TargetVIServer = ''
    }

    #endregion Choose the wave

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
    $credential = Get-MigrationCredential -VIServer $SourceVIServer -Credential $SourceCredential -NoPrompt:$NonInteractive
    if ($credential) { $connectParams.Credential = $credential }
    $sourceServer = Connect-VIServer @connectParams
    Write-BulkVMotionLog -Level Success -Message "Connected to $($sourceServer.Name) (version $($sourceServer.Version))."

    if ($runPhase -eq 3) {
        Write-BulkVMotionLog -Message "Connecting to target vCenter '$TargetVIServer'..."
        $connectParams = @{ Server = $TargetVIServer; ErrorAction = 'Stop' }
        $credential = Get-MigrationCredential -VIServer $TargetVIServer -Credential $TargetCredential -NoPrompt:$NonInteractive
        if ($credential) { $connectParams.Credential = $credential }
        $targetServer = Connect-VIServer @connectParams
        Write-BulkVMotionLog -Level Success -Message "Connected to $($targetServer.Name) (version $($targetServer.Version))."
    }
    else {
        $targetServer = $sourceServer
    }

    #endregion PowerCLI and connections

    #region Take the wave --------------------------------------------------------

    if ($ValidateOnly) {
        # A dry run does not claim the wave: it only reads, and writes back the port
        # groups it resolved.
        $wavePath = $wave.Path
    }
    else {
        $wavePath = Start-WaveRun -Wave $wave -RunningFolder $RunningFolder -Phase $runPhase
        Write-BulkVMotionLog -Message "The wave is yours for the duration of this run: $wavePath"
    }

    $exceptionMap  = Import-PortGroupExceptionMap -Path $PortGroupExceptionMap
    $sourcePgCache = Get-SourcePortGroupCache -Server $sourceServer
    $switchCache   = @{}
    $defaultSwitch = if ($TargetVDSwitch) { @($TargetVDSwitch)[0] } else { '' }

    #endregion Take the wave

    #region Settle the port groups for the whole wave ---------------------------

    # Phase 2 has no port groups, and -ValidateOnly already resolves everything without
    # migrating, so neither needs this pass.
    $preflightColumn = Get-PhasePortGroupColumn -Phase $runPhase
    $abortedByPreflight = $false

    if (-not $ValidateOnly -and $preflightColumn) {
        Write-BulkVMotionLog -Message 'Resolving the port groups for the whole wave before anything moves...'

        $resolved   = @()
        $unresolved = @()

        foreach ($row in $wave.Rows) {
            if ([int]$row.PhaseCompleted -ge $runPhase) { continue }

            try {
                $networkPlan = New-VMMigrationPlan -Row $row -Phase $runPhase -SourceServer $sourceServer -TargetServer $targetServer `
                    -SwitchCache $switchCache -PortGroupCache $sourcePgCache -ExceptionMap $exceptionMap `
                    -DefaultCluster $DefaultTargetCluster -DefaultDatastore $DefaultTargetDatastore `
                    -DefaultVDSwitch $defaultSwitch -NetworkOnly
            }
            catch {
                $unresolved += [pscustomobject]@{ VMName = $row.VMName; Reason = $_.Exception.Message }
                continue
            }

            if ($networkPlan.Ready -and $networkPlan.Mappings.Count -gt 0) {
                $resolved += [pscustomobject]@{
                    CsvLine          = $row.CsvLine
                    $preflightColumn = (ConvertTo-PortGroupList -Mapping $networkPlan.Mappings)
                }
                foreach ($detail in $networkPlan.NetworkDetails) {
                    Write-BulkVMotionLog -VMName $row.VMName -Message ('Network     : {0}' -f $detail)
                }
            }
            elseif (-not $networkPlan.Ready) {
                $unresolved += [pscustomobject]@{ VMName = $row.VMName; Reason = ($networkPlan.Errors -join ' / ') }
            }
        }

        # Whatever resolved is written down even when the rest of the wave did not, so the
        # engineer only has to deal with the rows that are actually a problem.
        if ($resolved.Count -gt 0) {
            Update-MigrationCsv -Path $wavePath -Update $resolved
            Write-BulkVMotionLog -Level Success -Message ('Resolved and recorded the port groups for {0} VM(s) in {1}.' -f $resolved.Count, $preflightColumn)
        }

        if ($unresolved.Count -gt 0) {
            $abortedByPreflight = $true
            $exitCode = 1
            Write-BulkVMotionLog -Level Error -Message ("{0} of {1} VM(s) have no port group, so nothing in this wave was migrated:" -f $unresolved.Count, $wave.VMCount)
            foreach ($entry in $unresolved) {
                Write-BulkVMotionLog -Level Error -VMName $entry.VMName -Message $entry.Reason
            }
            Write-BulkVMotionLog -Level Warning -Message ("Name the port group for those VM(s) in the {0} column of {1} and run phase {2} again. The rest of the wave is already resolved and recorded." -f $preflightColumn, $wave.Name, $runPhase)
        }
        else {
            # Re-read so the migration uses exactly the port groups just written, rather
            # than resolving a second time and possibly landing somewhere else.
            $wave.Rows = @(Import-MigrationCsv -Path $wavePath)
        }
    }

    #endregion Settle the port groups for the whole wave

    #region Migrate --------------------------------------------------------------

    $rows    = if ($abortedByPreflight) { @() } else { $wave.Rows }
    $summary['VMs total'] = $wave.VMCount

    $ledger  = New-MigrationCostLedger -NetworkMaximum $VMotionNetworkLimit
    Write-BulkVMotionLog -Message ('Concurrency              : vSphere cost model, host max 8, datastore max 128, vMotion network max {0}' -f $VMotionNetworkLimit)

    # Work items keep their plan once it is built, so a VM that has to wait for capacity
    # is not resolved against vCenter over and over.
    $work = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) { $work.Add([pscustomobject]@{ Row = $row; Plan = $null; Cost = $null }) | Out-Null }

    $running   = @()
    $completed = @()
    $aborted   = $false
    $lastExternalRefresh = [datetime]::MinValue

    while ($work.Count -gt 0 -or $running.Count -gt 0) {

        if (-not $IgnoreExternalTasks -and ((Get-Date) - $lastExternalRefresh).TotalSeconds -ge $PollIntervalSeconds) {
            $servers = @($sourceServer, $targetServer) | Where-Object { $_ } | Sort-Object -Property Name -Unique
            Update-ExternalMigrationCost -Ledger $ledger -Server $servers -OwnTaskId @($running | ForEach-Object { $_.Task.Id })
            $lastExternalRefresh = Get-Date
        }

        $startedThisCycle = 0
        $index = 0

        while (-not $aborted -and $index -lt $work.Count) {
            $item = $work[$index]
            $row  = $item.Row

            #region Resolve the plan for this VM, once
            if (-not $item.Plan) {
                if ([int]$row.PhaseCompleted -ge $runPhase) {
                    $completed += New-MigrationTracker -Plan (New-EmptyPlan -VMName $row.VMName -CsvLine $row.CsvLine -Phase $runPhase) `
                        -Status 'AlreadyDone' -Message "Completed phase $($row.PhaseCompleted) in an earlier run."
                    Write-BulkVMotionLog -VMName $row.VMName -Message "Already completed phase $runPhase in an earlier run - skipped."
                    $work.RemoveAt($index)
                    continue
                }

                Write-BulkVMotionLog -Message ('-' * 60)
                Write-BulkVMotionLog -VMName $row.VMName -Message "Preparing phase $runPhase (CSV line $($row.CsvLine))."

                try {
                    $plan = New-VMMigrationPlan -Row $row -Phase $runPhase -SourceServer $sourceServer -TargetServer $targetServer `
                        -SwitchCache $switchCache -PortGroupCache $sourcePgCache -ExceptionMap $exceptionMap `
                        -DefaultCluster $DefaultTargetCluster -DefaultDatastore $DefaultTargetDatastore `
                        -DefaultVDSwitch $defaultSwitch -DatastoreReserveGB $DatastoreReserveGB
                }
                catch {
                    $plan = New-EmptyPlan -VMName $row.VMName -CsvLine $row.CsvLine -Phase $runPhase
                    $plan.Errors = @($_.Exception.Message)
                }

                Write-MigrationPlanReport -Plan $plan

                if (-not $plan.Ready) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Failed' -Message (($plan.Errors) -join ' / ')
                    Write-BulkVMotionLog -Level Error -VMName $row.VMName -Message 'VM skipped - the plan could not be validated.'
                    if ($StopOnError) { $aborted = $true }
                    $work.RemoveAt($index)
                    continue
                }

                if ($plan.AlreadyInPlace) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'AlreadyDone' -Message "Nothing to do for phase $runPhase - the VM is already where this phase would put it."
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message "Nothing to do for phase $runPhase."
                    $work.RemoveAt($index)
                    continue
                }

                if ($ValidateOnly) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Skipped' -Message 'Validation only - the VM was not migrated.'
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message 'Plan is valid.'
                    $work.RemoveAt($index)
                    continue
                }

                if (-not $PSCmdlet.ShouldProcess($row.VMName, "phase $runPhase migration")) {
                    $completed += New-MigrationTracker -Plan $plan -Status 'Skipped' -Message 'Skipped by -WhatIf/-Confirm.'
                    $work.RemoveAt($index)
                    continue
                }

                $item.Plan = $plan
                $item.Cost = Get-MigrationCost -Plan $plan
            }
            #endregion Resolve the plan for this VM, once

            # Would starting this now push a host, datastore or the network over its limit?
            $admission = Test-MigrationAdmission -Ledger $ledger -Cost $item.Cost
            if (-not $admission.Allowed) {
                Write-BulkVMotionLog -Level Debug -VMName $row.VMName -Message "Waiting for capacity: $($admission.Reason)."
                $index++
                continue
            }

            try {
                $task = Start-VMMigrationTask -Plan $item.Plan -VMotionPriority $VMotionPriority -DiskStorageFormat $DiskStorageFormat

                if ($null -eq $task) {
                    # Port groups only - Start-VMMigrationTask did it synchronously.
                    $tracker = New-MigrationTracker -Plan $item.Plan -Status 'Success' -Message 'Network adapter(s) reconnected to the target port group(s); no vMotion was needed.'
                    $tracker.End = Get-Date
                    $completed += $tracker
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message 'Network adapter(s) reconnected to the target port group(s) - no vMotion was needed.'
                }
                else {
                    Add-MigrationCost -Ledger $ledger -Cost $item.Cost
                    $running += New-MigrationTracker -Plan $item.Plan -Task $task -Cost $item.Cost
                    $startedThisCycle++
                    Write-BulkVMotionLog -Level Success -VMName $row.VMName -Message "Migration started (task $($task.Id))."
                }
            }
            catch {
                $completed += New-MigrationTracker -Plan $item.Plan -Status 'Failed' -Message $_.Exception.Message
                Write-BulkVMotionLog -Level Error -VMName $row.VMName -Message "Could not start the migration: $($_.Exception.Message)"
                if ($StopOnError) { $aborted = $true }
            }

            $work.RemoveAt($index)
        }

        if ($running.Count -gt 0) {
            Start-Sleep -Seconds $PollIntervalSeconds
            $tracked  = $running
            $running  = @(Wait-VMMigrationTask -Tracker $tracked -TimeoutMinutes $MigrationTimeoutMinutes)
            $finished = @($tracked | Where-Object { $_.Status -ne 'Running' })

            foreach ($entry in $finished) {
                if ($entry.Cost) { Remove-MigrationCost -Ledger $ledger -Cost $entry.Cost }
            }
            $completed += $finished

            if ($StopOnError -and @($finished | Where-Object { $_.Status -ne 'Success' }).Count -gt 0) {
                $aborted = $true
            }
        }
        elseif ($work.Count -gt 0 -and $startedThisCycle -eq 0 -and -not $aborted) {
            # Nothing running and nothing could start: a VM wants more than a limit allows,
            # so waiting would never help.
            Write-BulkVMotionLog -Level Error -Message 'No migration can be started and none are running - the remaining VMs are blocked by a resource limit.'
            foreach ($item in $work) {
                $reason = (Test-MigrationAdmission -Ledger $ledger -Cost $item.Cost).Reason
                $completed += New-MigrationTracker -Plan $item.Plan -Status 'Failed' -Message "Blocked by a resource limit: $reason"
                Write-BulkVMotionLog -Level Error -VMName $item.Row.VMName -Message "Blocked by a resource limit: $reason"
            }
            $work.Clear()
            $aborted = $true
        }

        if ($aborted -and $work.Count -gt 0 -and $running.Count -eq 0) {
            Write-BulkVMotionLog -Level Warning -Message "Stopping early: the remaining $($work.Count) VM(s) in this wave will not be migrated."
            foreach ($item in $work) {
                $plan = if ($item.Plan) { $item.Plan } else { New-EmptyPlan -VMName $item.Row.VMName -CsvLine $item.Row.CsvLine -Phase $runPhase }
                $completed += New-MigrationTracker -Plan $plan -Status 'Skipped' -Message 'Not attempted - the run stopped early.'
            }
            $work.Clear()
        }
    }

    #endregion Migrate

    #region Result ---------------------------------------------------------------

    $succeeded   = @($completed | Where-Object { $_.Status -eq 'Success' })
    $failed      = @($completed | Where-Object { $_.Status -in @('Failed', 'TimedOut') })
    $skipped     = @($completed | Where-Object { $_.Status -eq 'Skipped' })
    $alreadyDone = @($completed | Where-Object { $_.Status -eq 'AlreadyDone' })

    $summary['VMs migrated']         = $succeeded.Count
    $summary['VMs failed']           = $failed.Count
    $summary['VMs skipped']          = $skipped.Count
    $summary['VMs already in place'] = $alreadyDone.Count

    if ($completed.Count -gt 0) {
        $resultPath = Join-Path $LogFolder ('{0}_phase{1}_{2}_result_{3}.csv' -f `
                [System.IO.Path]::GetFileNameWithoutExtension($wave.Name), $runPhase, $engineer, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $completed | ConvertTo-MigrationResult | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
        Write-BulkVMotionLog -Message "Per VM result written to $resultPath"
    }

    Write-BulkVMotionLog -Message ('Result for {0} phase {1}: {2} migrated, {3} already done, {4} failed, {5} skipped.' -f `
            $wave.Name, $runPhase, $succeeded.Count, $alreadyDone.Count, $failed.Count, $skipped.Count)
    foreach ($entry in $failed) {
        Write-BulkVMotionLog -Level Error -VMName $entry.VMName -Message ('{0}: {1}' -f $entry.Status, $entry.Message)
    }

    if ($failed.Count -gt 0) { $exitCode = 1 }

    #endregion Result

    #region Write the outcome into the wave --------------------------------------

    $portGroupColumn = Get-PhasePortGroupColumn -Phase $runPhase
    $stamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $updates = @()

    if ($ValidateOnly) {
        # Record only what the port groups would be, so they can be reviewed and
        # corrected before anything is migrated.
        if ($portGroupColumn) {
            foreach ($entry in $completed) {
                if (-not $entry.Plan.Mappings -or $entry.Plan.Mappings.Count -eq 0) { continue }
                $updates += [pscustomobject]@{
                    CsvLine         = $entry.CsvLine
                    $portGroupColumn = (ConvertTo-PortGroupList -Mapping $entry.Plan.Mappings)
                }
            }
        }

        if ($updates.Count -gt 0) {
            Update-MigrationCsv -Path $wavePath -Update $updates
            Write-BulkVMotionLog -Level Success -Message ("Wrote the resolved port groups for {0} VM(s) into {1}. Review the {2} column, correct anything ambiguous, then run the phase for real." -f $updates.Count, $wave.Name, $portGroupColumn)
        }
        Write-BulkVMotionLog -Message "Validation only - '$($wave.Name)' stays in IN and no phase was recorded."
    }
    else {
        foreach ($entry in @($succeeded + $alreadyDone)) {
            $plan = $entry.Plan
            $update = [ordered]@{
                CsvLine         = $entry.CsvLine
                PhaseCompleted  = $runPhase
                CompletedAt     = $stamp
                CompletedBy     = $engineer
                ResultVIServer  = $targetServer.Name
                ResultCluster   = $plan.TargetCluster
                ResultHost      = if ($plan.TargetHost) { $plan.TargetHost.Name } else { '' }
                ResultDatastore = $plan.DatastoreName
            }
            if ($portGroupColumn -and $plan.Mappings -and $plan.Mappings.Count -gt 0) {
                $update[$portGroupColumn] = ConvertTo-PortGroupList -Mapping $plan.Mappings
            }
            $updates += [pscustomobject]$update
        }

        if ($updates.Count -gt 0) {
            Update-MigrationCsv -Path $wavePath -Update $updates
            Write-BulkVMotionLog -Message ('Recorded phase {0} for {1} VM(s) in {2}.' -f $runPhase, $updates.Count, $wave.Name)
        }

        $waveDestination = Get-WaveHomeFolder -Path $wavePath
        if ($failed.Count -gt 0 -or $skipped.Count -gt 0) {
            Write-BulkVMotionLog -Level Warning -Message "'$($wave.Name)' still has VMs outstanding ($($failed.Count) failed, $($skipped.Count) skipped). Correct the failing rows and run phase $runPhase again - the VMs that are done will be skipped."
        }
    }

    #endregion Write the outcome into the wave
}
catch {
    $exitCode = 2
    Write-BulkVMotionLog -Level Error -Message "The run stopped: $($_.Exception.Message)"
    Write-BulkVMotionLog -Level Debug -Message ($_.ScriptStackTrace)
}
finally {
    # Release the wave whatever happened, so it is never stranded in Running.
    if ($wavePath -and -not $ValidateOnly) {
        try {
            if (-not $waveDestination) {
                $waveDestination = Get-WaveHomeFolder -Path $wavePath
                Write-BulkVMotionLog -Level Warning -Message "The run did not finish - '$([System.IO.Path]::GetFileName($wavePath))' is being returned to $(Split-Path -Leaf $waveDestination)."
            }
            $landed = Complete-WaveRun -Path $wavePath -Destination $waveDestination
            if ($landed) {
                Write-BulkVMotionLog -Level Success -Message "Wave file is now at $landed"
                if ($waveDestination -ne $InFolder -and $runPhase -lt 3) {
                    Write-BulkVMotionLog -Message "When the next wave is due, run phase $($runPhase + 1) and pick it from the list - there is nothing to move."
                }
            }
        }
        catch {
            Write-BulkVMotionLog -Level Error -Message "Could not release the wave file: $($_.Exception.Message). It is still in $RunningFolder and has to be moved back by hand."
            $exitCode = 2
        }
    }

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
    $summary['Engineer'] = $engineer
    $summary['Log file'] = $logFile
    Stop-BulkVMotionLog -Summary $summary
}

exit $exitCode
