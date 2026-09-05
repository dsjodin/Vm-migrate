<#
    End to end tests for Invoke-BulkVMotion.ps1.

    The script is run as a real child process against the PowerCLI test doubles in
    Tests\Fakes, so the whole flow is exercised: pick the wave, claim it in Running,
    connect, resolve each VM's switch, admit by cost, migrate, record the outcome in
    the CSV and archive it into the matching Phase folder.

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

    # The tests assert on the port group cell using the same parser the script uses.
    Import-Module (Join-Path (Join-Path (Join-Path $script:RepoRoot 'Modules') 'BulkVMotion') 'BulkVMotion.psd1') -Force

    function New-TestRun {
        param([string[]]$CsvContent, [string]$CsvName = 'wave1.csv')

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bvmrun-' + [guid]::NewGuid().ToString('N'))
        $paths = [pscustomobject]@{
            Root    = $root
            In      = Join-Path $root 'IN'
            Running = Join-Path $root 'Running'
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
            [switch]$NoTargetVIServer,
            [string]$ExternalTasks
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
            '-RunningFolder', $Paths.Running
            '-ArchiveRoot', $Paths.Archive
            '-LogFolder', $Paths.Logs
            '-ConfigFile', $Paths.Config
            '-PollIntervalSeconds', '5'
            '-DatastoreReserveGB', '10'
            '-NonInteractive'
        ) + $ExtraArguments

        $previous = @{
            ModulePath = $env:PSModulePath
            FakeLog    = $env:BVM_FAKE_LOG
            FakeState  = $env:BVM_FAKE_STATE
            External   = $env:BVM_EXTERNAL_TASKS
        }
        try {
            $env:PSModulePath       = $script:FakeRoot + [System.IO.Path]::PathSeparator + $previous.ModulePath
            $env:BVM_FAKE_LOG       = $Paths.FakeLog
            # Each phase is its own process, so the inventory has to persist between them.
            $env:BVM_FAKE_STATE     = $Paths.State
            $env:BVM_EXTERNAL_TASKS = $ExternalTasks
            $output = & $script:PwshPath @arguments 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        }
        finally {
            $env:PSModulePath       = $previous.ModulePath
            $env:BVM_FAKE_LOG       = $previous.FakeLog
            $env:BVM_FAKE_STATE     = $previous.FakeState
            $env:BVM_EXTERNAL_TASKS = $previous.External
        }
    }

    function Get-InFiles      { param($Paths) @(Get-ChildItem -LiteralPath $Paths.In -File -ErrorAction SilentlyContinue) }
    function Get-RunningFiles { param($Paths) @(Get-ChildItem -LiteralPath $Paths.Running -File -ErrorAction SilentlyContinue) }

    function Get-PhaseFiles {
        param($Paths, [int]$Phase)
        @(Get-ChildItem -LiteralPath (Join-Path $Paths.Archive ('Phase{0}' -f $Phase)) -File -ErrorAction SilentlyContinue)
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

    function Get-PeakConcurrency {
        <#
            Replays the START/END lines the fake recorded and returns the highest number
            of simultaneous operations of one kind that any single host ever carried.
        #>
        param($Paths, [string]$Operation)

        $inFlight = @{}
        $peak     = @{}
        $owner    = @{}

        foreach ($line in (Get-Calls -Paths $Paths)) {
            if ($line -match '^START (?<vm>\S+) (?<host>\S+) (?<op>\S+)$') {
                if ($Matches.op -ne $Operation) { continue }
                $vmHost = $Matches.host
                $owner[$Matches.vm] = $vmHost
                $inFlight[$vmHost] = [int]$inFlight[$vmHost] + 1
                if ([int]$inFlight[$vmHost] -gt [int]$peak[$vmHost]) { $peak[$vmHost] = $inFlight[$vmHost] }
            }
            elseif ($line -match '^END (?<vm>\S+)$') {
                $vmHost = $owner[$Matches.vm]
                if ($vmHost) { $inFlight[$vmHost] = [math]::Max(0, [int]$inFlight[$vmHost] - 1) }
            }
        }

        if ($peak.Count -eq 0) { return 0 }
        return (($peak.Values | Measure-Object -Maximum).Maximum)
    }
}

Describe 'Phase 1 - cluster change and VDS remap' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'vMotions to the new cluster, remaps by VLAN and leaves storage alone' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-app-02')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0

        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-app-01 -> host=esx-new-\d+\.corp\.local datastore=none portgroups=PG-NEW-Prod-100'
        $calls | Should -Match 'MOVE vm-app-02 .*portgroups=PG-NEW-Test-200'
        # datastore=none is the point of phase 1: the disks do not move.
        $calls | Should -Not -Match 'datastore=DS-'
    }

    It 'records the phase, the engineer and the port groups, then archives into Phase1' {
        $script:Paths = New-TestRun -CsvContent @('VMName,Notes', 'vm-app-01,first wave')

        Invoke-Runner -Paths $script:Paths -Phase 1 | Out-Null

        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count      | Should -Be 0
        (Get-RunningFiles -Paths $script:Paths).Count | Should -Be 0

        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 1 | Select-Object -First 1
        $archived.PhaseCompleted   | Should -Be '1'
        $archived.CompletedBy      | Should -Not -BeNullOrEmpty
        $archived.ResultCluster    | Should -Be 'CL-NEW-01'
        $archived.ResultHost       | Should -Match '^esx-new-\d+\.corp\.local$'
        $archived.Phase1PortGroups | Should -Be 'Network adapter 1=PG-NEW-Prod-100'
        $archived.Notes            | Should -Be 'first wave'
    }

    It 'refuses a VM whose datastore the new cluster cannot see' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-nosan-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match "Datastore 'DS-ISOLATED' is not mounted"
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'migrates nothing when one VM has no port group, then does the lot on the re-run' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-dmz-01')

        $first = Invoke-Runner -Paths $script:Paths -Phase 1
        $first.ExitCode | Should -Be 1

        # All or nothing: vm-app-01 resolves fine but is not moved, because vm-dmz-01
        # cannot be. Finding that out after five VMs had already moved is the thing this
        # prevents.
        (Get-Calls -Paths $script:Paths).Count        | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count      | Should -Be 1
        (Get-RunningFiles -Paths $script:Paths).Count | Should -Be 0
        $first.Output | Should -Match 'nothing in this wave was migrated'

        $inProgress = @(Import-Csv -LiteralPath $script:Paths.Csv)
        ($inProgress | Where-Object { $_.VMName -eq 'vm-app-01' }).PhaseCompleted | Should -Be '0'
        ($inProgress | Where-Object { $_.VMName -eq 'vm-dmz-01' }).PhaseCompleted | Should -Be '0'

        # The work the run did do is kept: the VM that resolved has its port group written
        # down, so only the problem row needs touching.
        ($inProgress | Where-Object { $_.VMName -eq 'vm-app-01' }).Phase1PortGroups |
            Should -Be 'Network adapter 1=PG-NEW-Prod-100'
        ($inProgress | Where-Object { $_.VMName -eq 'vm-dmz-01' }).Phase1PortGroups |
            Should -BeNullOrEmpty

        # Name the port group for the one row that needs it, then run the wave again.
        $fixed = $inProgress | ForEach-Object {
            if ($_.VMName -eq 'vm-dmz-01') { $_.Phase1PortGroups = 'Network adapter 1=PG-NEW-Test-200' }
            $_
        }
        $fixed | Export-Csv -LiteralPath $script:Paths.Csv -NoTypeInformation

        $second = Invoke-Runner -Paths $script:Paths -Phase 1
        $second.ExitCode | Should -Be 0

        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-app-01 .*portgroups=PG-NEW-Prod-100'
        $calls | Should -Match 'MOVE vm-dmz-01 .*portgroups=PG-NEW-Test-200'
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
    }

    It 'records the port groups for every VM before the first one moves' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-multinic-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        $run.Output   | Should -Match 'Resolving the port groups for the whole wave before anything moves'

        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 1
        ($archived | Where-Object { $_.VMName -eq 'vm-app-01' }).Phase1PortGroups |
            Should -Be 'Network adapter 1=PG-NEW-Prod-100'
        ($archived | Where-Object { $_.VMName -eq 'vm-multinic-01' }).Phase1PortGroups |
            Should -Be 'Network adapter 1=PG-NEW-Prod-100; Network adapter 2=PG-NEW-Bkp-300'
    }

    It 'aborts the wave without a dry run having been needed' {
        # No -ValidateOnly anywhere: the real run does the resolving itself.
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-app-02', 'vm-dmz-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        # The message names the VM to fix and the column to fix it in.
        $run.Output | Should -Match 'vm-dmz-01'
        $run.Output | Should -Match 'Phase1PortGroups column'

        $rows = @(Import-Csv -LiteralPath $script:Paths.Csv)
        @($rows | Where-Object { $_.Phase1PortGroups }).Count | Should -Be 2
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
}

Describe 'Pinning a destination host' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sends the VM to the host named in the CSV, not the emptiest one' {
        # esx-new-02 has the most free memory, so it is what the script would pick on its
        # own. Naming esx-new-01 has to beat that.
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,Phase1Cluster,Phase1Host'
            'vm-app-01,CL-NEW-01,esx-new-01.corp.local'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths) -join '' | Should -Match 'MOVE vm-app-01 -> host=esx-new-01\.corp\.local'
        $run.Output | Should -Match 'pinned in the CSV'
        (Get-ArchivedCsv -Paths $script:Paths -Phase 1)[0].ResultHost | Should -Be 'esx-new-01.corp.local'
    }

    It 'refuses a pinned host that sits in a different cluster' {
        # esx-old-01 exists, but it is in CL-OLD-01. Without the check the VM would go
        # there and the cluster named in the row would be silently ignored.
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,Phase1Cluster,Phase1Host'
            'vm-app-01,CL-NEW-01,esx-old-01.corp.local'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message |
            Should -Match "is in cluster 'CL-OLD-01', not the target cluster 'CL-NEW-01'"
    }

    It 'refuses a pinned host that is in maintenance' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,Phase1Cluster,Phase1Host'
            'vm-app-01,CL-NEW-01,esx-new-09.corp.local'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message |
            Should -Match 'is Maintenance, so the VM cannot be migrated to it'
    }

    It 'refuses a pinned host that does not exist' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,Phase1Cluster,Phase1Host'
            'vm-app-01,CL-NEW-01,esx-typo-99.corp.local'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match 'was not found'
    }

    It 'never picks a host that is in maintenance when choosing on its own' {
        # esx-new-09 has the most free memory of all, but it is in maintenance.
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths) -join '' | Should -Not -Match 'esx-new-09'
    }

    It 'pins a host on the new vCenter in phase 3' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase3Cluster,Phase3Host'
            'vm-phase2-01,2,CL-FINAL-01,esx-vc2-02.corp.local'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths) -join '' | Should -Match 'host=esx-vc2-02\.corp\.local'
    }
}

Describe 'Multiple NICs and per VM switches' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'maps each NIC onto the port group carrying its own VLAN' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-multinic-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        # VLAN 100 and VLAN 300 land on different port groups, in adapter order.
        (Get-Calls -Paths $script:Paths) -join "`n" |
            Should -Match 'MOVE vm-multinic-01 .*portgroups=PG-NEW-Prod-100\+PG-NEW-Bkp-300'
    }

    It 'records both NICs in one cell and reads them back as overrides' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-multinic-01')

        Invoke-Runner -Paths $script:Paths -Phase 1 | Out-Null

        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 1 | Select-Object -First 1
        $archived.Phase1PortGroups | Should -Be 'Network adapter 1=PG-NEW-Prod-100; Network adapter 2=PG-NEW-Bkp-300'

        # That same cell, fed back in, has to pin both adapters.
        $map = ConvertFrom-PortGroupList -Value $archived.Phase1PortGroups
        $map['Network adapter 1'] | Should -Be 'PG-NEW-Prod-100'
        $map['Network adapter 2'] | Should -Be 'PG-NEW-Bkp-300'
    }

    It 'honours a per adapter override that names only the second NIC' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,Phase1PortGroups'
            'vm-multinic-01,Network adapter 2=PG-NEW-Test-200'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        # Adapter 1 still resolved by VLAN; adapter 2 went where the cell said.
        (Get-Calls -Paths $script:Paths) -join "`n" |
            Should -Match 'portgroups=PG-NEW-Prod-100\+PG-NEW-Test-200'
    }

    It 'sends two VMs in one wave to the switches their rows name' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,Phase1VDS'
            'vm-multinic-01,VDS-NEW'
            'vm-multinic-02,VDS-NEW-B'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-multinic-01 .*portgroups=PG-NEW-Prod-100\+PG-NEW-Bkp-300'
        $calls | Should -Match 'MOVE vm-multinic-02 .*portgroups=PG-B-Prod-100\+PG-B-Bkp-300'
    }
}

Describe 'Dry run' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fills in the port groups it resolved without migrating or archiving' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-multinic-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1 -ExtraArguments @('-ValidateOnly')

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths).Count       | Should -Be 0
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 0
        (Get-RunningFiles -Paths $script:Paths).Count | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count      | Should -Be 1

        $row = @(Import-Csv -LiteralPath $script:Paths.Csv)[0]
        $row.Phase1PortGroups | Should -Be 'Network adapter 1=PG-NEW-Prod-100; Network adapter 2=PG-NEW-Bkp-300'
        # The phase is untouched: nothing was actually done.
        $row.PhaseCompleted   | Should -Be '0'
    }

    It 'leaves the wave ready to run for real straight afterwards' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')

        Invoke-Runner -Paths $script:Paths -Phase 1 -ExtraArguments @('-ValidateOnly') | Out-Null
        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
    }
}

Describe 'Phase 2 - storage only' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Storage vMotions thin, without a destination host or a network change' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 0
        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-phase1-01 -> host=none datastore=DS-NEW-01 portgroups=none'
        $calls | Should -Not -Match 'SETNIC'
    }

    It 'holds the third Storage vMotion on a host until one of the first two finishes' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
            'vm-phase1-02,1,DS-NEW-01'
            'vm-phase1-03,1,DS-NEW-01'
            'vm-phase1-04,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 0
        # All four are on esx-new-01, and a host carries at most 2 Storage vMotions.
        @(Get-Calls -Paths $script:Paths | Where-Object { $_ -like 'MOVE *' }).Count | Should -Be 4
        Get-PeakConcurrency -Paths $script:Paths -Operation 'svmotion' | Should -BeLessOrEqual 2
    }

    It 'gives way to Storage vMotions another engineer already has on that host' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
            'vm-phase1-02,1,DS-NEW-01'
        )

        # Someone else is already running two Storage vMotions on esx-new-01, which uses
        # the host's whole budget of 8.
        $run = Invoke-Runner -Paths $script:Paths -Phase 2 -ExternalTasks 'vm-phase1-03=relocate;vm-phase1-04=relocate'

        # Nothing can start and nothing is running, so the run says so rather than hanging.
        $run.Output | Should -Match 'blocked by a resource limit|Blocked by a resource limit'
        (Get-Calls -Paths $script:Paths | Where-Object { $_ -like 'MOVE *' }).Count | Should -Be 0
        # Every VM still has phase 1 behind it, so the wave belongs in Phase1 and is
        # offered again next time phase 2 is run.
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
        (Get-RunningFiles -Paths $script:Paths).Count        | Should -Be 0
    }

    It 'ignores other engineers when told to' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2 `
            -ExternalTasks 'vm-phase1-03=relocate;vm-phase1-04=relocate' `
            -ExtraArguments @('-IgnoreExternalTasks')

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths) -join '' | Should -Match 'MOVE vm-phase1-01'
    }

    It 'runs phase 2 without a port group pre-flight' {
        # Phase 2 has no port groups, so the pre-flight must not get in the way.
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 0
        $run.Output   | Should -Not -Match 'Resolving the port groups'
        (Get-Calls -Paths $script:Paths) -join '' | Should -Match 'MOVE vm-phase1-01'
    }

    It 'fails the VM when no target datastore is given' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase1-01,1')

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 1
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match 'target datastore is required'
    }
}

Describe 'Phase 3 - cross vCenter, same storage' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'moves to the new vCenter keeping the datastore and remapping onto its VDS' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,2')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths) -join "`n" |
            Should -Match 'MOVE vm-phase2-01 -> host=esx-vc2-\d+\.corp\.local datastore=DS-NEW-01 portgroups=PG-VC2-Prod-100'
    }

    It 'records the new vCenter and its port groups, and archives into Phase3' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,2')

        Invoke-Runner -Paths $script:Paths -Phase 3 | Out-Null

        $archived = Get-ArchivedCsv -Paths $script:Paths -Phase 3 | Select-Object -First 1
        $archived.PhaseCompleted   | Should -Be '3'
        $archived.ResultVIServer   | Should -Be 'vc-new.corp.local'
        $archived.ResultCluster    | Should -Be 'CL-FINAL-01'
        $archived.ResultDatastore  | Should -Be 'DS-NEW-01'
        $archived.Phase3PortGroups | Should -Be 'Network adapter 1=PG-VC2-Prod-100'
    }

    It 'aborts a phase 3 wave when a VM cannot be mapped onto the new VDS' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted'
            'vm-phase2-01,2'
            'vm-dmz-01,2'
        )

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        $run.Output | Should -Match 'nothing in this wave was migrated'

        # Nothing was migrated, so every row still has phase 2 as its highest, and the
        # wave belongs in Phase2 rather than IN.
        (Get-PhaseFiles -Paths $script:Paths -Phase 2).Count | Should -Be 1
        (Get-RunningFiles -Paths $script:Paths).Count        | Should -Be 0

        # The one that did resolve is recorded against the phase 3 column.
        $rows = Get-ArchivedCsv -Paths $script:Paths -Phase 2
        ($rows | Where-Object { $_.VMName -eq 'vm-phase2-01' }).Phase3PortGroups |
            Should -Be 'Network adapter 1=PG-VC2-Prod-100'
    }

    It 'refuses to run without a target vCenter' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,2')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3 -NoTargetVIServer

        $run.ExitCode | Should -Be 2
        $run.Output   | Should -Match '-TargetVIServer is required'
    }

    It 'refuses phase 3 when the VM never had its storage moved in phase 2' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase1-01,2')

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 1
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message |
            Should -Match "Datastore 'DS-OLD-01' was not found on vc-new.corp.local"
    }
}

Describe 'Waves on a shared mgmt server' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a wave that is due for a different phase than the run' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase1-01,1')

        # The wave has phase 1 behind it, so it is due for phase 2, not phase 1.
        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 2
        $run.Output   | Should -Match 'needs exactly one runnable wave'
        (Get-Calls -Paths $script:Paths).Count   | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'runs the wave named with -CsvFile without the picker' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')
        @('VMName', 'vm-app-02') -join "`n" | Set-Content -LiteralPath (Join-Path $script:Paths.In 'wave2.csv')

        # Two runnable waves, so -NonInteractive alone would refuse; naming one is how a
        # scripted run picks.
        $run = Invoke-Runner -Paths $script:Paths -Phase 1 -ExtraArguments @('-CsvFile', (Join-Path $script:Paths.In 'wave2.csv'))

        $run.ExitCode | Should -Be 0
        (Get-Calls -Paths $script:Paths) -join '' | Should -Match 'MOVE vm-app-02'
        (Get-Calls -Paths $script:Paths) -join '' | Should -Not -Match 'MOVE vm-app-01'
        # wave1 was left alone for whoever wants it.
        (Get-InFiles -Paths $script:Paths).Name | Should -Be 'wave1.csv'
    }

    It 'refuses to guess when several waves could be run' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')
        @('VMName', 'vm-app-02') -join "`n" | Set-Content -LiteralPath (Join-Path $script:Paths.In 'wave2.csv')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 2
        $run.Output   | Should -Match 'needs exactly one runnable wave, but there are 2'
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
    }

    It 'will not touch a wave another engineer is running' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')

        # Move it into Running and claim it for a live process that is not ours.
        New-Item -ItemType Directory -Path $script:Paths.Running -Force | Out-Null
        $claimed = Join-Path $script:Paths.Running 'wave1.csv'
        Move-Item -LiteralPath $script:Paths.Csv -Destination $claimed
        @{
            Engineer = 'CORP\bob'; Machine = $env:COMPUTERNAME; ProcessId = $PID
            ProcessStartedAt = (Get-Process -Id $PID).StartTime.ToString('o')
            StartedAt = (Get-Date).ToString('o'); Phase = 1; Wave = 'wave1.csv'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Paths.Running 'wave1.run.json')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 2
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
        # Still theirs, untouched.
        (Get-RunningFiles -Paths $script:Paths).Name | Should -Contain 'wave1.csv'
    }

    It 'resumes a wave left behind by a run that died' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')

        New-Item -ItemType Directory -Path $script:Paths.Running -Force | Out-Null
        $stranded = Join-Path $script:Paths.Running 'wave1.csv'
        Move-Item -LiteralPath $script:Paths.Csv -Destination $stranded
        @{
            Engineer = 'CORP\bob'; Machine = $env:COMPUTERNAME; ProcessId = 999999
            ProcessStartedAt = (Get-Date).AddHours(-2).ToString('o')
            StartedAt = (Get-Date).AddHours(-2).ToString('o'); Phase = 1; Wave = 'wave1.csv'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Paths.Running 'wave1.run.json')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        $run.Output   | Should -Match 'Resuming a wave that was interrupted'
        (Get-Calls -Paths $script:Paths) -join '' | Should -Match 'MOVE vm-app-01'
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
        (Get-RunningFiles -Paths $script:Paths).Count        | Should -Be 0
    }

    It 'never leaves a wave stranded in Running when the run fails' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-fail-task')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-RunningFiles -Paths $script:Paths).Count | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count      | Should -Be 1
    }

    It 'ignores a target vCenter that came from the config on a single vCenter phase' {
        # config/settings.json describes the whole project, phase 3 included, and is read
        # by every run - so a TargetVIServer in it must not break phases 1 and 2.
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')
        @{
            TargetVIServer = 'vc-new.corp.local'
        } | ConvertTo-Json | Set-Content -LiteralPath $script:Paths.Config

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 0
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
    }

    It 'still refuses a target vCenter named on the command line for phase 1' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')

        # Naming it on the command line for phase 1 is a mistake worth stopping for.
        $run = Invoke-Runner -Paths $script:Paths -Phase 1 -ExtraArguments @('-TargetVIServer', 'vc-new.corp.local')

        $run.ExitCode | Should -Be 2
        $run.Output   | Should -Match 'Only phase 3 crosses vCenters'
        (Get-Calls -Paths $script:Paths).Count | Should -Be 0
    }

    It 'names the log after the engineer who ran it' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01')

        Invoke-Runner -Paths $script:Paths -Phase 1 | Out-Null

        $log = Get-ChildItem -LiteralPath $script:Paths.Logs -Filter '*.log' | Select-Object -First 1
        $log.Name | Should -BeLike "*$env:USERNAME*"
    }

    It 'picks up a wave waiting in Phase1 without anything being moved by hand' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
        )
        # Put it where a phase 1 run would have left it.
        $phase1 = Join-Path $script:Paths.Archive 'Phase1'
        New-Item -ItemType Directory -Path $phase1 -Force | Out-Null
        Move-Item -LiteralPath $script:Paths.Csv -Destination $phase1

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 0
        (Get-PhaseFiles -Paths $script:Paths -Phase 2).Count | Should -Be 1
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 0
    }

    It 'returns a part finished phase 2 wave to Phase1, not to IN' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,PhaseCompleted,Phase2Datastore'
            'vm-phase1-01,1,DS-NEW-01'
            'vm-phase1-02,1,'
        )
        $phase1 = Join-Path $script:Paths.Archive 'Phase1'
        New-Item -ItemType Directory -Path $phase1 -Force | Out-Null
        Move-Item -LiteralPath $script:Paths.Csv -Destination $phase1

        $run = Invoke-Runner -Paths $script:Paths -Phase 2

        $run.ExitCode | Should -Be 1
        # Every VM has phase 1 behind it, so Phase1 is where the wave belongs - putting it
        # in IN would read as though it had never started.
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count             | Should -Be 0
        (Get-RunningFiles -Paths $script:Paths).Count        | Should -Be 0

        $rows = Import-Csv -LiteralPath (Get-PhaseFiles -Paths $script:Paths -Phase 1)[0].FullName
        ($rows | Where-Object { $_.VMName -eq 'vm-phase1-01' }).PhaseCompleted | Should -Be '2'
        ($rows | Where-Object { $_.VMName -eq 'vm-phase1-02' }).PhaseCompleted | Should -Be '1'
    }

    It 'still returns a part finished phase 1 wave to IN' {
        $script:Paths = New-TestRun -CsvContent @('VMName', 'vm-app-01', 'vm-dmz-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count             | Should -Be 1
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 0
    }

    It 'does not offer a wave that has finished phase 3' {
        $script:Paths = New-TestRun -CsvContent @('VMName,PhaseCompleted', 'vm-phase2-01,3')
        $phase3 = Join-Path $script:Paths.Archive 'Phase3'
        New-Item -ItemType Directory -Path $phase3 -Force | Out-Null
        Move-Item -LiteralPath $script:Paths.Csv -Destination $phase3

        $run = Invoke-Runner -Paths $script:Paths -Phase 3

        $run.ExitCode | Should -Be 2
        $run.Output   | Should -Match 'needs exactly one runnable wave, but there are 0'
    }

    It 'reports a broken CSV and leaves it in IN' {
        $script:Paths = New-TestRun -CsvContent @('Name,Cluster', 'vm-app-01,CL-NEW-01')

        $run = Invoke-Runner -Paths $script:Paths -Phase 1

        $run.ExitCode | Should -Be 2
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'carries one wave through all three phases with no file moved by hand' {
        $script:Paths = New-TestRun -CsvContent @('VMName,Phase2Datastore', 'vm-app-01,DS-NEW-01')

        # There is deliberately no Move-Item anywhere in this test. Each phase finds the
        # wave where the previous one left it; if that ever regresses, this fails.
        (Invoke-Runner -Paths $script:Paths -Phase 1).ExitCode | Should -Be 0
        $afterPhase1 = Get-PhaseFiles -Paths $script:Paths -Phase 1 | Select-Object -First 1
        $afterPhase1 | Should -Not -BeNullOrEmpty
        (Import-Csv -LiteralPath $afterPhase1.FullName)[0].Phase1PortGroups | Should -Be 'Network adapter 1=PG-NEW-Prod-100'

        (Invoke-Runner -Paths $script:Paths -Phase 2).ExitCode | Should -Be 0
        $afterPhase2 = Get-PhaseFiles -Paths $script:Paths -Phase 2 | Select-Object -First 1
        $afterPhase2 | Should -Not -BeNullOrEmpty
        (Import-Csv -LiteralPath $afterPhase2.FullName)[0].PhaseCompleted | Should -Be '2'
        # It left Phase1 on its own.
        (Get-PhaseFiles -Paths $script:Paths -Phase 1).Count | Should -Be 0

        (Invoke-Runner -Paths $script:Paths -Phase 3).ExitCode | Should -Be 0

        $final = Get-ArchivedCsv -Paths $script:Paths -Phase 3 | Select-Object -First 1
        $final.PhaseCompleted   | Should -Be '3'
        $final.ResultVIServer   | Should -Be 'vc-new.corp.local'
        $final.ResultDatastore  | Should -Be 'DS-NEW-01'
        # Each phase recorded its own port groups.
        $final.Phase1PortGroups | Should -Be 'Network adapter 1=PG-NEW-Prod-100'
        $final.Phase3PortGroups | Should -Be 'Network adapter 1=PG-VC2-Prod-100'

        $calls = (Get-Calls -Paths $script:Paths) -join "`n"
        $calls | Should -Match 'MOVE vm-app-01 -> host=esx-new-\d+\.corp\.local datastore=none portgroups=PG-NEW-Prod-100'
        $calls | Should -Match 'MOVE vm-app-01 -> host=none datastore=DS-NEW-01 portgroups=none'
        $calls | Should -Match 'MOVE vm-app-01 -> host=esx-vc2-\d+\.corp\.local datastore=DS-NEW-01 portgroups=PG-VC2-Prod-100'
    }
}
