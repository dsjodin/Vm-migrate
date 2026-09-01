<#
    End to end tests for Invoke-BulkVMotion.ps1.

    The script is run as a real child process against the PowerCLI test doubles in
    Tests\Fakes, so the whole flow is exercised: read the CSV, settle the phase,
    connect, build the VLAN table, plan, migrate, record the phase in the file and
    archive it into the matching Phase folder.

    Run with:  Invoke-Pester -Path .\Tests
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper names read better in the plural.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build fixtures; there is nothing to confirm.')]
param()

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'Invoke-BulkVMotion.ps1'
    $script:FakeRoot   = Join-Path $PSScriptRoot 'Fakes'
    $script:PwshPath   = (Get-Process -Id $PID).Path

    function New-TestRun {
        <#
            Creates an isolated IN/archive/LOGS set plus an empty config file, so a
            settings.json in the working copy cannot influence the test.
        #>
        param([string[]]$CsvContent, [string]$CsvName = 'wave1.csv')

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bvmrun-' + [guid]::NewGuid().ToString('N'))
        $paths = [pscustomobject]@{
            Root    = $root
            In      = Join-Path $root 'IN'
            Archive = $root
            Logs    = Join-Path $root 'LOGS'
            Config  = Join-Path $root 'empty-config.json'
            FakeLog = Join-Path $root 'vsphere-calls.txt'
            State   = Join-Path $root 'vsphere-state.json'
            Csv     = $null
        }
        foreach ($dir in @($paths.In, $paths.Logs)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        '{}' | Set-Content -LiteralPath $paths.Config
        $paths.Csv = Join-Path $paths.In $CsvName
        $CsvContent -join "`n" | Set-Content -LiteralPath $paths.Csv
        return $paths
    }

    function Invoke-Runner {
        param(
            [pscustomobject]$Paths,
            [int]$Phase = 1,
            [string[]]$ExtraArguments = @(),
            [switch]$NoPhaseArgument,
            [switch]$NoTargetVIServer
        )

        $phaseArguments = if ($NoPhaseArgument) { @() } else { @('-Phase', "$Phase") }

        # Phase 3 is the only one that crosses vCenters, and it maps onto the second
        # vCenter's switch.
        $topology = if ($Phase -eq 3) {
            $vc = if ($NoTargetVIServer) { @() } else { @('-TargetVIServer', 'vc-new.corp.local') }
            $vc + @('-TargetVDSwitch', 'VDS-VC2', '-DefaultTargetCluster', 'CL-FINAL-01')
        }
        else {
            @('-TargetVDSwitch', 'VDS-NEW', '-DefaultTargetCluster', 'CL-NEW-01')
        }

        $arguments = @('-NoLogo', '-NoProfile', '-File', $script:ScriptPath, '-SourceVIServer', 'vc-old.corp.local') +
        $phaseArguments + $topology + @(
            '-InFolder', $Paths.In
            '-ArchiveRoot', $Paths.Archive
            '-LogFolder', $Paths.Logs
            '-ConfigFile', $Paths.Config
            '-PollIntervalSeconds', '5'
            '-DatastoreReserveGB', '10'
        ) + $ExtraArguments

        $previousModulePath = $env:PSModulePath
        $previousFakeLog    = $env:BVM_FAKE_LOG
        $previousFakeState  = $env:BVM_FAKE_STATE
        try {
            $env:PSModulePath   = $script:FakeRoot + [System.IO.Path]::PathSeparator + $previousModulePath
            $env:BVM_FAKE_LOG   = $Paths.FakeLog
            # Each phase is its own process, so the inventory has to persist between them.
            $env:BVM_FAKE_STATE = $Paths.State
            $output = & $script:PwshPath @arguments 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        }
        finally {
            $env:PSModulePath   = $previousModulePath
            $env:BVM_FAKE_LOG   = $previousFakeLog
            $env:BVM_FAKE_STATE = $previousFakeState
        }
    }

    function Get-InFiles { param($Paths) @(Get-ChildItem -LiteralPath $Paths.In -File -ErrorAction SilentlyContinue) }

    function Get-PhaseFiles {
        param($Paths, [int]$Phase)
        $folder = Join-Path $Paths.Archive ('Phase{0}' -f $Phase)
        @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)
    }

    function Get-ArchivedCsv {
        param($Paths, [int]$Phase)
        $file = Get-PhaseFiles -Paths $Paths -Phase $Phase | Select-Object -First 1
        if (-not $file) { return @() }
        return @(Import-Csv -LiteralPath $file.FullName)
    }

    function Get-ResultCsv {
        param($Paths)
        $file = Get-ChildItem -LiteralPath $Paths.Logs -Filter '*_result_*.csv' -File | Sort-Object Name | Select-Object -Last 1
        if (-not $file) { return @() }
        return @(Import-Csv -LiteralPath $file.FullName)
    }

    function Get-Calls {
        param($Paths)
        if (-not (Test-Path -LiteralPath $Paths.FakeLog)) { return @() }
        return @(Get-Content -LiteralPath $Paths.FakeLog)
    }
}

Describe 'Phase 1 - cluster change and VDS remap' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'vMotions to the new cluster, remaps the port groups by VLAN and leaves storage alone' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-app-02')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0

        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-app-01 -> host=esx-new-\d+\.corp\.local datastore=none portgroups=PG-NEW-Prod-100'
        $calls | Should -Match 'MOVE vm-app-02 .*portgroups=PG-NEW-Test-200'

        # datastore=none is the point of phase 1: the disks do not move.
        $calls | Should -Not -Match 'datastore=DS-'
    }

    It 'records the phase in the CSV and archives it into Phase1' {
        $script:Paths = New-TestRun -CsvContent @('VMName,Notes', 'vm-app-01,first wave')

        Invoke-Runner -Paths $script:Paths -Phase 1 | Out-Null

        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 0

        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 1 | Select-Object -First 1
        $archived.PhaseCompleted  | Should -Be '1'
        $archived.ResultCluster   | Should -Be 'CL-NEW-01'
        $archived.ResultHost      | Should -Match '^esx-new-\d+\.corp\.local$'
        $archived.ResultPortGroup | Should -Be 'PG-NEW-Prod-100'
        $archived.CompletedAt     | Should -Not -BeNullOrEmpty
        # The operator's own columns survive.
        $archived.Notes           | Should -Be 'first wave'
    }

    It 'refuses a VM whose datastore the new cluster cannot see' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-nosan-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match "Datastore 'DS-ISOLATED' is not mounted"
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'keeps the file in IN when a VM cannot be mapped, and completes it on the re-run' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-dmz-01')

        $first = Invoke-Runner -Paths $script:Paths -Phase 1
        $first.ExitCode | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1

        # vm-app-01 migrated and is now recorded in the file that stayed behind.
        $inProgress = @(Import-Csv -LiteralPath $script:Paths.Csv)
        ($inProgress | Where-Object { $_.VMName -eq 'vm-app-01' }).PhaseCompleted | Should -Be '1'
        ($inProgress | Where-Object { $_.VMName -eq 'vm-dmz-01' }).PhaseCompleted | Should -Be '0'

        # Fix the failing row the way an operator would, then run the same file again.
        $fixed = $inProgress | ForEach-Object {
            $value = if ($_.VMName -eq 'vm-dmz-01') { 'PG-NEW-Test-200' } else { '' }
            $_ | Add-Member -NotePropertyName 'Phase1PortGroup' -NotePropertyValue $value -Force -PassThru
        }
        $fixed | Export-Csv -LiteralPath $script:Paths.Csv -NoTypeInformation

        $second = Invoke-Runner -Paths $script:Paths -Phase 1
        $second.ExitCode | Should -Be 0

        # Only the outstanding VM was touched on the re-run.
        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        @([regex]::Matches($calls, 'MOVE vm-app-01')).Count | Should -Be 1
        $calls | Should -Match 'MOVE vm-dmz-01 .*portgroups=PG-NEW-Test-200'

        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 0
    }

    It 'reports a VM an earlier run already moved without touching it' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-phase1-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Status | Should -Be 'AlreadyDone'
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
    }

    It 'reconnects the adapters without a vMotion when only the port group differs' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-netonly-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'SETNIC vm-netonly-01 Network adapter 1 -> PG-NEW-Prod-100'
        $calls | Should -Not -Match 'MOVE '
    }

    It 'migrates nothing and leaves the file untouched with -ValidateOnly' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')
        $before = Get-Content -LiteralPath $script:Paths.Csv -Raw

        Invoke-Runner -Paths $script:Paths -Phase 1 -ExtraArguments @('-ValidateOnly') | Out-Null

        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
        Get-Content -LiteralPath $script:Paths.Csv -Raw | Should -Be $before
    }
}

Describe 'Phase 2 - storage only' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Storage vMotions without naming a destination host or touching the network' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 0

        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        # No destination host and no port groups - this is a pure svMotion.
        $calls | Should -Match 'MOVE vm-phase1-01 -> host=none datastore=DS-NEW-01 portgroups=none'
        $calls | Should -Not -Match 'SETNIC'
    }

    It 'archives into Phase2 and records the datastore the VM landed on' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )

        Invoke-Runner -Paths $script:Paths -Phase 2 | Out-Null

        (Get-PhaseFiles -Paths $script:Paths -Phase 2).Count | Should -Be 1
        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 2 | Select-Object -First 1
        $archived.PhaseCompleted  | Should -Be '2'
        $archived.ResultDatastore | Should -Be 'DS-NEW-01'
    }

    It 'fails the VM when no target datastore is given' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase1-01,1')

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 1
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match 'target datastore is required'
    }

    It 'reports a VM that is already on the target datastore' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase2-01,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Status | Should -Be 'AlreadyDone'
    }
}

Describe 'Phase 3 - cross vCenter, same storage' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'moves to the new vCenter keeping the same datastore and remapping onto its VDS' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,2')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 0

        # The datastore is passed unchanged - same shared LUN as the new vCenter sees it -
        # and the port group is the second vCenter's, matched on VLAN 100 again.
        (Get-Calls -Paths $script:Paths) -join "`n" |
            Should -Match 'MOVE vm-phase2-01 -> host=esx-vc2-\d+\.corp\.local datastore=DS-NEW-01 portgroups=PG-VC2-Prod-100'
    }

    It 'archives into Phase3 and records the new vCenter' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,2')

        Invoke-Runner -Paths $script:Paths -Phase 3 | Out-Null

        (Get-PhaseFiles -Paths $script:Paths -Phase 3).Count | Should -Be 1
        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 3 | Select-Object -First 1
        $archived.PhaseCompleted  | Should -Be '3'
        $archived.ResultVIServer  | Should -Be 'vc-new.corp.local'
        $archived.ResultCluster   | Should -Be 'CL-FINAL-01'
        $archived.ResultDatastore | Should -Be 'DS-NEW-01'
    }

    It 'refuses to run without a target vCenter' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,2')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3 -NoTargetVIServer

        $run.ExitCode | Should -Be 2
        $run.Output   | Should -Match '-TargetVIServer is required'
    }
}

Describe 'Phase handling across a whole wave' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a file that is due for a different phase than the run' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase1-01,1')

        # The file has phase 1 behind it, so it is due for phase 2, not phase 1.
        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        $run.Output   | Should -Match 'due for phase 2 but the run was started with -Phase 1'
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'takes the phase from the file when -Phase is not given' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2 -NoPhaseArgument

        $run.ExitCode | Should -Be 0
        $run.Output   | Should -Match 'Phase\s+: 2 \(taken from the CSV files\)'
        (Get-PhaseFiles -Paths $script:Paths -Phase 2).Count | Should -Be 1
    }

    It 'carries one file through all three phases' {
        $script:Paths = New-TestRun -CsvContent @('VMName,Phase2Datastore', 'vm-app-01,DS-NEW-01')

        # Phase 1: old cluster -> new cluster, new VDS.
        (Invoke-Runner -Paths $script:Paths -Phase 1).ExitCode | Should -Be 0
        $afterPhase1 = Get-PhaseFiles -Paths $script:Paths -Phase 1 | Select-Object -First 1
        $afterPhase1 | Should -Not -BeNullOrEmpty

        # The VM really is in the new cluster on the new VDS now, still on its old storage.
        (Import-Csv -LiteralPath $afterPhase1.FullName)[0].ResultPortGroup | Should -Be 'PG-NEW-Prod-100'

        # The operator brings the file back for the storage wave.
        Move-Item -LiteralPath $afterPhase1.FullName -Destination $script:Paths.Csv

        (Invoke-Runner -Paths $script:Paths -Phase 2).ExitCode | Should -Be 0
        $afterPhase2 = Get-PhaseFiles -Paths $script:Paths -Phase 2 | Select-Object -First 1
        $afterPhase2 | Should -Not -BeNullOrEmpty
        (Import-Csv -LiteralPath $afterPhase2.FullName)[0].PhaseCompleted | Should -Be '2'

        # And again for the cross vCenter wave.
        Move-Item -LiteralPath $afterPhase2.FullName -Destination $script:Paths.Csv

        (Invoke-Runner -Paths $script:Paths -Phase 3).ExitCode | Should -Be 0
        $final = Get-ArchivedCsv -Paths $script:Paths -Phase 3 | Select-Object -First 1
        $final.PhaseCompleted | Should -Be '3'
        $final.ResultVIServer | Should -Be 'vc-new.corp.local'
        # Phase 3 kept the storage phase 2 put it on - the shared LUN, not the old one.
        $final.ResultDatastore | Should -Be 'DS-NEW-01'
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 0

        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-app-01 -> host=esx-new-\d+\.corp\.local datastore=none portgroups=PG-NEW-Prod-100'
        $calls | Should -Match 'MOVE vm-app-01 -> host=none datastore=DS-NEW-01 portgroups=none'
        $calls | Should -Match 'MOVE vm-app-01 -> host=esx-vc2-\d+\.corp\.local datastore=DS-NEW-01 portgroups=PG-VC2-Prod-100'
    }

    It 'refuses phase 3 when the VM never had its storage moved in phase 2' {
        # Still on DS-OLD-01, which the new vCenter cannot see.
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase1-01,2')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message |
            Should -Match "Datastore 'DS-OLD-01' was not found on vc-new.corp.local"
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'reports a finished wave that is dropped back into IN and re-archives it' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,3')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3 -NoPhaseArgument

        $run.Output | Should -Match 'every VM has completed phase 3'
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-PhaseFiles -Paths $script:Paths -Phase 3).Count | Should -Be 1
    }

    It 'reports a broken CSV and leaves it in IN' {
        $script:Paths = New-TestRun -CsvContent @('Name,TargetCluster', 'vm-app-01,CL-NEW-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        $run.Output   | Should -Match 'missing required column'
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'records a failed vCenter task and keeps the file for a retry' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-fail-task')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match 'not compatible'
    }

    It 'processes several files in one wave' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')
        @('VMName', 'vm-app-02') -join "`n" | Set-Content -LiteralPath (Join-Path $script:Paths.In 'wave2.csv')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 2
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 0
    }
}
