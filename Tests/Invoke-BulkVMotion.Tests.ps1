<#
    End to end tests for Invoke-BulkVMotion.ps1.

    The script is run as a real child process against the PowerCLI test doubles in
    Tests\Fakes, so the whole flow is exercised: connect, build the VLAN table, plan,
    migrate, write the result CSV and move the CSV file to MOVED.

    Run with:  Invoke-Pester -Path .\Tests
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper names read better in the plural.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build fixtures; there is nothing to confirm.')]
param()

BeforeAll {
    $script:RepoRoot  = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'Invoke-BulkVMotion.ps1'
    $script:FakeRoot   = Join-Path $PSScriptRoot 'Fakes'
    $script:PwshPath   = (Get-Process -Id $PID).Path

    function New-TestRun {
        <#
            Creates an isolated IN/MOVED/LOGS set plus an empty config file, so a
            settings.json in the working copy cannot influence the test.
        #>
        param([string[]]$CsvContent, [string]$CsvName = 'wave1.csv')

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bvmrun-' + [guid]::NewGuid().ToString('N'))
        $paths = [pscustomobject]@{
            Root    = $root
            In      = Join-Path $root 'IN'
            Moved   = Join-Path $root 'MOVED'
            Logs    = Join-Path $root 'LOGS'
            Config  = Join-Path $root 'empty-config.json'
            FakeLog = Join-Path $root 'movevm-calls.txt'
            Csv     = $null
        }
        foreach ($dir in @($paths.In, $paths.Moved, $paths.Logs)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        '{}' | Set-Content -LiteralPath $paths.Config
        $paths.Csv = Join-Path $paths.In $CsvName
        $CsvContent -join "`n" | Set-Content -LiteralPath $paths.Csv
        return $paths
    }

    function Invoke-Runner {
        param([pscustomobject]$Paths, [string[]]$ExtraArguments = @())

        $arguments = @(
            '-NoLogo', '-NoProfile', '-File', $script:ScriptPath
            '-SourceVIServer', 'vc-old.corp.local'
            '-TargetVIServer', 'vc-new.corp.local'
            '-TargetVDSwitch', 'VDS-NEW'
            '-DefaultTargetCluster', 'CL-NEW-01'
            '-DefaultTargetDatastore', 'DS-NEW-01'
            '-InFolder', $Paths.In
            '-MovedFolder', $Paths.Moved
            '-LogFolder', $Paths.Logs
            '-ConfigFile', $Paths.Config
            '-PollIntervalSeconds', '5'
            '-DatastoreReserveGB', '10'
        ) + $ExtraArguments

        $previousModulePath = $env:PSModulePath
        $previousFakeLog    = $env:BVM_FAKE_LOG
        try {
            $env:PSModulePath = $script:FakeRoot + [System.IO.Path]::PathSeparator + $previousModulePath
            $env:BVM_FAKE_LOG = $Paths.FakeLog
            $output = & $script:PwshPath @arguments 2>&1
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = ($output | Out-String)
            }
        }
        finally {
            $env:PSModulePath = $previousModulePath
            $env:BVM_FAKE_LOG = $previousFakeLog
        }
    }

    function Get-MovedFiles { param($Paths) @(Get-ChildItem -LiteralPath $Paths.Moved -File -ErrorAction SilentlyContinue) }
    function Get-InFiles    { param($Paths) @(Get-ChildItem -LiteralPath $Paths.In -File -ErrorAction SilentlyContinue) }
    function Get-ResultCsv {
        param($Paths)
        $file = Get-ChildItem -LiteralPath $Paths.Logs -Filter '*_result_*.csv' -File | Select-Object -First 1
        if (-not $file) { return @() }
        return @(Import-Csv -LiteralPath $file.FullName)
    }
    function Get-MoveCalls {
        param($Paths)
        if (-not (Test-Path -LiteralPath $Paths.FakeLog)) { return @() }
        return @(Get-Content -LiteralPath $Paths.FakeLog)
    }
}

Describe 'Invoke-BulkVMotion end to end' {

    AfterEach {
        if ($script:Paths -and (Test-Path -LiteralPath $script:Paths.Root)) {
            Remove-Item -LiteralPath $script:Paths.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'migrates every VM, maps the port groups by VLAN and moves the CSV to MOVED' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore'
            'vm-app-01,CL-NEW-01,DS-NEW-01'
            'vm-app-02,CL-NEW-01,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 0

        # The CSV was archived and the IN folder is empty again.
        $moved = Get-MovedFiles -Paths $script:Paths
        $moved.Count | Should -Be 1
        $moved[0].Name | Should -Match '^wave1_\d{8}-\d{6}\.csv$'
        (Get-InFiles -Paths $script:Paths).Count | Should -Be 0

        # Both VMs really went through Move-VM, onto the VLAN matched port groups.
        $calls = Get-MoveCalls -Paths $script:Paths
        $calls.Count | Should -Be 2
        ($calls -join "`n") | Should -Match 'MOVE vm-app-01 .*portgroups=PG-NEW-Prod-100'
        ($calls -join "`n") | Should -Match 'MOVE vm-app-02 .*portgroups=PG-NEW-Test-200'

        # The result CSV records both migrations.
        $results = Get-ResultCsv -Paths $script:Paths
        $results.Count | Should -Be 2
        @($results | Where-Object { $_.Status -eq 'Success' }).Count | Should -Be 2
        ($results | Where-Object { $_.VMName -eq 'vm-app-01' }).TargetDatastore | Should -Be 'DS-NEW-01'
        ($results | Where-Object { $_.VMName -eq 'vm-app-01' }).NetworkMapping  | Should -Match 'VLAN 100'
    }

    It 'writes a log file that documents the VLAN table and every migration' {
        $script:Paths = New-TestRun -CsvContent @('VMName,TargetCluster,TargetDatastore', 'vm-app-01,CL-NEW-01,DS-NEW-01')

        Invoke-Runner -Paths $script:Paths | Out-Null

        $log = Get-ChildItem -LiteralPath $script:Paths.Logs -Filter '*.log' -File | Select-Object -First 1
        $log | Should -Not -BeNullOrEmpty

        $content = Get-Content -LiteralPath $log.FullName -Raw
        $content | Should -Match 'Bulk vMotion run started'
        $content | Should -Match 'Target port group VLAN table'
        $content | Should -Match 'VLAN:100\s+-> PG-NEW-Prod-100'
        $content | Should -Match '\[vm-app-01\] Migration started'
        $content | Should -Match '\[vm-app-01\] Migration completed'
        $content | Should -Match 'Bulk vMotion run finished'
    }

    It 'leaves the CSV in IN when a VM cannot be mapped to a target port group' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore'
            'vm-app-01,CL-NEW-01,DS-NEW-01'
            'vm-dmz-01,CL-NEW-01,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 1
        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count    | Should -Be 1

        # The healthy VM still migrated; only the unmappable one failed.
        (Get-MoveCalls -Paths $script:Paths).Count | Should -Be 1

        $results = Get-ResultCsv -Paths $script:Paths
        ($results | Where-Object { $_.VMName -eq 'vm-app-01' }).Status | Should -Be 'Success'
        $failed = $results | Where-Object { $_.VMName -eq 'vm-dmz-01' }
        $failed.Status  | Should -Be 'Failed'
        $failed.Message | Should -Match 'VLAN 999'
    }

    It 'records a failed vCenter task and keeps the CSV for a retry' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore'
            'vm-fail-task,CL-NEW-01,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 1
        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 0

        $result = Get-ResultCsv -Paths $script:Paths | Select-Object -First 1
        $result.Status  | Should -Be 'Failed'
        $result.Message | Should -Match 'not compatible'
    }

    It 'fails the VM when the target datastore has too little free space' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore'
            'vm-huge-01,CL-NEW-01,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 1
        (Get-MoveCalls -Paths $script:Paths).Count | Should -Be 0
        (Get-ResultCsv -Paths $script:Paths | Select-Object -First 1).Message | Should -Match 'GB free'
    }

    It 'migrates nothing and keeps the CSV when -ValidateOnly is used' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore'
            'vm-app-01,CL-NEW-01,DS-NEW-01'
            'vm-dmz-01,CL-NEW-01,DS-NEW-01'
        )

        $run = Invoke-Runner -Paths $script:Paths -ExtraArguments @('-ValidateOnly')

        # vm-dmz-01 cannot be mapped, so the run still reports a failure.
        $run.ExitCode | Should -Be 1
        (Get-MoveCalls -Paths $script:Paths).Count | Should -Be 0
        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 0
        (Get-InFiles -Paths $script:Paths).Count    | Should -Be 1

        $results = Get-ResultCsv -Paths $script:Paths
        ($results | Where-Object { $_.VMName -eq 'vm-app-01' }).Status | Should -Be 'Skipped'
        ($results | Where-Object { $_.VMName -eq 'vm-dmz-01' }).Status | Should -Be 'Failed'
    }

    It 'honours an explicit TargetPortGroup from the CSV' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore,TargetPortGroup'
            'vm-dmz-01,CL-NEW-01,DS-NEW-01,PG-NEW-Test-200'
        )

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 0
        (Get-MoveCalls -Paths $script:Paths) -join '' | Should -Match 'portgroups=PG-NEW-Test-200'
        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 1
    }

    It 'processes several CSV files in one run and archives each of them' {
        $script:Paths = New-TestRun -CsvContent @('VMName,TargetCluster,TargetDatastore', 'vm-app-01,CL-NEW-01,DS-NEW-01')
        @('VMName,TargetCluster,TargetDatastore', 'vm-app-02,CL-NEW-01,DS-NEW-01') -join "`n" |
            Set-Content -LiteralPath (Join-Path $script:Paths.In 'wave2.csv')

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 0
        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 2
        (Get-InFiles -Paths $script:Paths).Count    | Should -Be 0
        (Get-MoveCalls -Paths $script:Paths).Count  | Should -Be 2
    }

    It 'reports a broken CSV and leaves it in IN' {
        $script:Paths = New-TestRun -CsvContent @('Name,TargetCluster', 'vm-app-01,CL-NEW-01')

        $run = Invoke-Runner -Paths $script:Paths

        $run.ExitCode | Should -Be 1
        $run.Output   | Should -Match 'missing required column'
        (Get-InFiles -Paths $script:Paths).Count    | Should -Be 1
        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 0
    }

    It 'always archives the CSV when -MoveCsvWhen Always is used, even after a failure' {
        $script:Paths = New-TestRun -CsvContent @(
            'VMName,TargetCluster,TargetDatastore'
            'vm-app-01,CL-NEW-01,DS-NEW-01'
            'vm-dmz-01,CL-NEW-01,DS-NEW-01'
        )

        Invoke-Runner -Paths $script:Paths -ExtraArguments @('-MoveCsvWhen', 'Always') | Out-Null

        (Get-MovedFiles -Paths $script:Paths).Count | Should -Be 1
        (Get-InFiles -Paths $script:Paths).Count    | Should -Be 0
    }
}
