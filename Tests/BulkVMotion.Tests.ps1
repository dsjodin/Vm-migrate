<#
    Unit tests for the parts of BulkVMotion that do not need a vCenter connection:
    VLAN parsing, port group matching, CSV validation and the CSV archive move.

    Run with:  Invoke-Pester -Path .\Tests
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper names read better in the plural.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build fixtures; there is nothing to confirm.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'A throwaway password for a fake credential object; it never reaches a real system.')]
param()

BeforeAll {
    $script:ModulePath = Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules') 'BulkVMotion') 'BulkVMotion.psd1'
    Import-Module $script:ModulePath -Force

    # Stand-ins for the vSphere VLAN spec types. Get-PortGroupVlanInfo branches on the
    # type name, so the names have to match what the vSphere API returns.
    class VmwareDistributedVirtualSwitchVlanIdSpec { [int]$VlanId }
    class VmwareDistributedVirtualSwitchTrunkVlanSpec { $VlanId }
    class VmwareDistributedVirtualSwitchPvlanSpec { [int]$PvlanId }
    class NumericRange { [int]$Start; [int]$End }

    function New-FakeVDPortGroup {
        param(
            [string]$Name,
            $VlanSpec,
            [bool]$IsUplink = $false
        )
        [pscustomobject]@{
            Name          = $Name
            IsUplink      = $IsUplink
            ExtensionData = [pscustomobject]@{
                Config = [pscustomobject]@{
                    DefaultPortConfig = [pscustomobject]@{ Vlan = $VlanSpec }
                }
            }
        }
    }

    function New-AccessVlanSpec {
        param([int]$VlanId)
        $spec = [VmwareDistributedVirtualSwitchVlanIdSpec]::new()
        $spec.VlanId = $VlanId
        return $spec
    }

    function New-TrunkVlanSpec {
        param([int]$Start, [int]$End)
        $range = [NumericRange]::new(); $range.Start = $Start; $range.End = $End
        $spec = [VmwareDistributedVirtualSwitchTrunkVlanSpec]::new()
        $spec.VlanId = @($range)
        return $spec
    }
}

Describe 'Get-PortGroupVlanInfo' {

    It 'reads an access VLAN from a distributed port group' {
        $pg = New-FakeVDPortGroup -Name 'PG-OLD-Prod-100' -VlanSpec (New-AccessVlanSpec -VlanId 100)
        $info = Get-PortGroupVlanInfo -PortGroup $pg

        $info.Type   | Should -Be 'Access'
        $info.VlanId | Should -Be 100
        $info.Key    | Should -Be 'VLAN:100'
    }

    It 'treats VLAN 0 as untagged' {
        $info = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-None' -VlanSpec (New-AccessVlanSpec -VlanId 0))

        $info.Type | Should -Be 'None'
        $info.Key  | Should -Be 'VLAN:0'
    }

    It 'reads a trunk range and never matches a plain access VLAN' {
        $trunk  = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-Trunk' -VlanSpec (New-TrunkVlanSpec -Start 100 -End 200))
        $access = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-100' -VlanSpec (New-AccessVlanSpec -VlanId 100))

        $trunk.Type | Should -Be 'Trunk'
        $trunk.Key  | Should -Be 'TRUNK:100-200'
        $trunk.Key  | Should -Not -Be $access.Key
    }

    It 'reads a private VLAN' {
        $spec = [VmwareDistributedVirtualSwitchPvlanSpec]::new(); $spec.PvlanId = 110
        $info = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-PVLAN' -VlanSpec $spec)

        $info.Type   | Should -Be 'PrivateVlan'
        $info.VlanId | Should -Be 110
        $info.Key    | Should -Be 'PVLAN:110'
    }

    It 'reads the VLAN of a standard vSwitch port group' {
        $info = Get-PortGroupVlanInfo -PortGroup ([pscustomobject]@{ Name = 'VM Network'; VLanId = 250 })

        $info.Type   | Should -Be 'Access'
        $info.VlanId | Should -Be 250
        $info.Key    | Should -Be 'VLAN:250'
    }

    It 'treats standard port group VLAN 4095 as a trunk' {
        $info = Get-PortGroupVlanInfo -PortGroup ([pscustomobject]@{ Name = 'VGT'; VLanId = 4095 })

        $info.Type | Should -Be 'Trunk'
        $info.Key  | Should -Be 'TRUNK:0-4094'
    }

    It 'reports Unknown when the VLAN cannot be determined' {
        $info = Get-PortGroupVlanInfo -PortGroup ([pscustomobject]@{ Name = 'Mystery' })

        $info.Type | Should -Be 'Unknown'
        $info.Key  | Should -BeNullOrEmpty
    }
}

Describe 'Get-VlanPortGroupMap' {

    It 'keys the map by VLAN and skips uplink port groups' {
        $portGroups = @(
            New-FakeVDPortGroup -Name 'PG-NEW-Prod-100' -VlanSpec (New-AccessVlanSpec -VlanId 100)
            New-FakeVDPortGroup -Name 'PG-NEW-Test-200' -VlanSpec (New-AccessVlanSpec -VlanId 200)
            New-FakeVDPortGroup -Name 'VDS-NEW-Uplinks' -VlanSpec (New-TrunkVlanSpec -Start 0 -End 4094) -IsUplink $true
        )

        $map = Get-VlanPortGroupMap -PortGroup $portGroups

        $map.Keys.Count           | Should -Be 2
        $map['VLAN:100'].Name     | Should -Be 'PG-NEW-Prod-100'
        $map.ContainsKey('TRUNK:0-4094') | Should -BeFalse
    }

    It 'keeps every candidate when two target port groups share a VLAN' {
        $map = Get-VlanPortGroupMap -PortGroup @(
            New-FakeVDPortGroup -Name 'PG-A-100' -VlanSpec (New-AccessVlanSpec -VlanId 100)
            New-FakeVDPortGroup -Name 'PG-B-100' -VlanSpec (New-AccessVlanSpec -VlanId 100)
        )

        @($map['VLAN:100']).Count | Should -Be 2
    }
}

Describe 'Resolve-TargetPortGroup' {

    BeforeAll {
        $script:TargetPortGroups = @(
            New-FakeVDPortGroup -Name 'PG-NEW-Prod-100' -VlanSpec (New-AccessVlanSpec -VlanId 100)
            New-FakeVDPortGroup -Name 'PG-NEW-Test-200' -VlanSpec (New-AccessVlanSpec -VlanId 200)
        )
        $script:Map = Get-VlanPortGroupMap -PortGroup $script:TargetPortGroups
    }

    It 'matches the source port group to the target port group with the same VLAN' {
        $source = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-OLD-Prod' -VlanSpec (New-AccessVlanSpec -VlanId 100))
        $result = Resolve-TargetPortGroup -SourceVlanInfo $source -Map $script:Map -AvailablePortGroup $script:TargetPortGroups

        $result.Success        | Should -BeTrue
        $result.PortGroup.Name | Should -Be 'PG-NEW-Prod-100'
        $result.MatchedBy      | Should -Be 'VlanId'
    }

    It 'fails with a reason when no target port group carries the VLAN' {
        $source = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-OLD-DMZ' -VlanSpec (New-AccessVlanSpec -VlanId 999))
        $result = Resolve-TargetPortGroup -SourceVlanInfo $source -Map $script:Map -AvailablePortGroup $script:TargetPortGroups

        $result.Success | Should -BeFalse
        $result.Reason  | Should -Match 'VLAN 999'
    }

    It 'refuses to guess when the VLAN exists on several target port groups' {
        $ambiguous = @(
            New-FakeVDPortGroup -Name 'PG-A-300' -VlanSpec (New-AccessVlanSpec -VlanId 300)
            New-FakeVDPortGroup -Name 'PG-B-300' -VlanSpec (New-AccessVlanSpec -VlanId 300)
        )
        $map    = Get-VlanPortGroupMap -PortGroup $ambiguous
        $source = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-OLD-300' -VlanSpec (New-AccessVlanSpec -VlanId 300))
        $result = Resolve-TargetPortGroup -SourceVlanInfo $source -Map $map -AvailablePortGroup $ambiguous

        $result.Success | Should -BeFalse
        $result.Reason  | Should -Match 'several target port groups'
    }

    It 'breaks a VLAN tie when one candidate has the same name as the source' {
        $ambiguous = @(
            New-FakeVDPortGroup -Name 'PG-Prod-300' -VlanSpec (New-AccessVlanSpec -VlanId 300)
            New-FakeVDPortGroup -Name 'PG-Other-300' -VlanSpec (New-AccessVlanSpec -VlanId 300)
        )
        $map    = Get-VlanPortGroupMap -PortGroup $ambiguous
        $source = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-Prod-300' -VlanSpec (New-AccessVlanSpec -VlanId 300))
        $result = Resolve-TargetPortGroup -SourceVlanInfo $source -Map $map -AvailablePortGroup $ambiguous

        $result.Success        | Should -BeTrue
        $result.PortGroup.Name | Should -Be 'PG-Prod-300'
        $result.MatchedBy      | Should -Be 'VlanId+Name'
    }

    It 'lets an explicit override win over the VLAN lookup' {
        $source = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-OLD-Prod' -VlanSpec (New-AccessVlanSpec -VlanId 100))
        $result = Resolve-TargetPortGroup -SourceVlanInfo $source -Map $script:Map -Override 'PG-NEW-Test-200' -AvailablePortGroup $script:TargetPortGroups

        $result.Success        | Should -BeTrue
        $result.PortGroup.Name | Should -Be 'PG-NEW-Test-200'
        $result.MatchedBy      | Should -Be 'Override'
    }

    It 'fails when the override port group does not exist' {
        $source = Get-PortGroupVlanInfo -PortGroup (New-FakeVDPortGroup -Name 'PG-OLD-Prod' -VlanSpec (New-AccessVlanSpec -VlanId 100))
        $result = Resolve-TargetPortGroup -SourceVlanInfo $source -Map $script:Map -Override 'PG-DOES-NOT-EXIST' -AvailablePortGroup $script:TargetPortGroups

        $result.Success | Should -BeFalse
        $result.Reason  | Should -Match 'does not exist'
    }
}

Describe 'Import-MigrationCsv' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns one normalised row per VM with every known column present' {
        $path = Join-Path $script:TestRoot 'wave1.csv'
        "VMName,Phase1Cluster`nvm-app-01,CL-NEW-01`nvm-app-02,CL-NEW-01" | Set-Content -LiteralPath $path

        $rows = @(Import-MigrationCsv -Path $path)

        $rows.Count               | Should -Be 2
        $rows[0].VMName           | Should -Be 'vm-app-01'
        $rows[0].Phase1Cluster    | Should -Be 'CL-NEW-01'
        $rows[0].Phase2Datastore  | Should -Be ''
        $rows[0].Phase1PortGroups | Should -Be ''
        $rows[0].CsvLine          | Should -Be 2
        $rows[1].CsvLine          | Should -Be 3
    }

    It 'trims whitespace around values' {
        $path = Join-Path $script:TestRoot 'spaces.csv'
        "VMName,Phase1Cluster`n  vm-app-01  ,  CL-NEW-01  " | Set-Content -LiteralPath $path

        (Import-MigrationCsv -Path $path).VMName | Should -Be 'vm-app-01'
    }

    It 'throws when the VMName column is missing' {
        $path = Join-Path $script:TestRoot 'bad.csv'
        "Name,Phase1Cluster`nvm-app-01,CL-NEW-01" | Set-Content -LiteralPath $path

        { Import-MigrationCsv -Path $path } | Should -Throw '*missing required column*'
    }

    It 'throws when the file has no data rows' {
        $path = Join-Path $script:TestRoot 'empty.csv'
        'VMName,Phase1Cluster' | Set-Content -LiteralPath $path

        { Import-MigrationCsv -Path $path } | Should -Throw '*no data rows*'
    }

    It 'throws when the file does not exist' {
        { Import-MigrationCsv -Path (Join-Path $script:TestRoot 'nope.csv') } | Should -Throw '*not found*'
    }

    It 'skips rows with an empty VMName' {
        $path = Join-Path $script:TestRoot 'gap.csv'
        "VMName,Phase1Cluster`nvm-app-01,CL-NEW-01`n,CL-NEW-01" | Set-Content -LiteralPath $path

        @(Import-MigrationCsv -Path $path).Count | Should -Be 1
    }
}

Describe 'Move-ProcessedCsv' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        $script:InDir    = Join-Path $script:TestRoot 'IN'
        $script:MovedDir = Join-Path $script:TestRoot 'MOVED'
        New-Item -ItemType Directory -Path $script:InDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'moves the file to MOVED, creating the folder and stamping the name' {
        $source = Join-Path $script:InDir 'wave1.csv'
        'VMName' | Set-Content -LiteralPath $source

        $destination = Move-ProcessedCsv -Path $source -Destination $script:MovedDir

        Test-Path -LiteralPath $source      | Should -BeFalse
        Test-Path -LiteralPath $destination | Should -BeTrue
        [System.IO.Path]::GetFileName($destination) | Should -Match '^wave1_\d{8}-\d{6}\.csv$'
    }

    It 'never overwrites a file already archived under the same name' {
        $first = Join-Path $script:InDir 'wave1.csv'
        'first' | Set-Content -LiteralPath $first
        $firstDestination = Move-ProcessedCsv -Path $first -Destination $script:MovedDir

        $second = Join-Path $script:InDir 'wave1.csv'
        'second' | Set-Content -LiteralPath $second
        $secondDestination = Move-ProcessedCsv -Path $second -Destination $script:MovedDir

        $secondDestination                              | Should -Not -Be $firstDestination
        Get-Content -LiteralPath $firstDestination -Raw | Should -Match 'first'
        (Get-ChildItem -LiteralPath $script:MovedDir).Count | Should -Be 2
    }
}

Describe 'Import-PortGroupExceptionMap' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns an empty map when no path is given' {
        (Import-PortGroupExceptionMap -Path '').Count | Should -Be 0
    }

    It 'maps source port group names to target port group names' {
        $path = Join-Path $script:TestRoot 'exceptions.csv'
        "SourcePortGroup,TargetPortGroup,Comment`nPG-OLD-DMZ,PG-NEW-DMZ,renamed`nPG-OLD-Bad,,incomplete" | Set-Content -LiteralPath $path

        $map = Import-PortGroupExceptionMap -Path $path

        $map.Count            | Should -Be 1
        $map['PG-OLD-DMZ']    | Should -Be 'PG-NEW-DMZ'
    }
}

Describe 'Module surface' {

    It 'exports every function the runner script calls' {
        $module = Get-Module BulkVMotion
        foreach ($name in @('Start-BulkVMotionLog', 'Stop-BulkVMotionLog', 'Write-BulkVMotionLog',
                'Import-MigrationCsv', 'Move-ProcessedCsv', 'Get-VlanPortGroupMap',
                'Write-VlanPortGroupMapReport', 'Import-PortGroupExceptionMap',
                'Get-SourcePortGroupCache', 'New-VMMigrationPlan', 'Write-MigrationPlanReport',
                'Start-VMMigrationTask', 'Wait-VMMigrationTask', 'New-MigrationTracker',
                'ConvertTo-MigrationResult')) {
            $module.ExportedFunctions.Keys | Should -Contain $name
        }
    }
}

Describe 'Get-CsvNextPhase' {

    BeforeAll {
        function New-PhaseRow {
            param([string]$VMName, [int]$PhaseCompleted)
            [pscustomobject]@{ VMName = $VMName; PhaseCompleted = $PhaseCompleted }
        }
    }

    It 'starts a fresh file at phase 1' {
        $result = Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 0), (New-PhaseRow -VMName 'vm-b' -PhaseCompleted 0))

        $result.Phase      | Should -Be 1
        $result.IsComplete | Should -BeFalse
        $result.Reason     | Should -BeNullOrEmpty
    }

    It 'moves a file on to the next phase once every row has the current one behind it' {
        (Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 1), (New-PhaseRow -VMName 'vm-b' -PhaseCompleted 1))).Phase | Should -Be 2
        (Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 2))).Phase | Should -Be 3
    }

    It 'stays on the current phase while any row is behind' {
        # Eight VMs made it through phase 1, two did not: still a phase 1 file.
        $rows = @(1..8 | ForEach-Object { New-PhaseRow -VMName "vm-$_" -PhaseCompleted 1 }) +
                @(9..10 | ForEach-Object { New-PhaseRow -VMName "vm-$_" -PhaseCompleted 0 })

        (Get-CsvNextPhase -Row $rows).Phase | Should -Be 1
    }

    It 'reports a wave where every VM has finished phase 3' {
        $result = Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 3))

        $result.IsComplete | Should -BeTrue
        $result.Phase      | Should -Be 4
    }

    It 'refuses the file when the run asserts a different phase' {
        $result = Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 1)) -Assert 1

        $result.Reason | Should -Match 'due for phase 2 but the run was started with -Phase 1'
    }

    It 'accepts the file when the asserted phase agrees' {
        (Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 1)) -Assert 2).Reason | Should -BeNullOrEmpty
    }

    It 'asserts nothing when the run did not state a phase' {
        (Get-CsvNextPhase -Row @((New-PhaseRow -VMName 'vm-a' -PhaseCompleted 1)) -Assert 0).Reason | Should -BeNullOrEmpty
    }
}

Describe 'Get-PhaseRowValue' {

    It 'prefers the phase column over the run default' {
        $row = [pscustomobject]@{ Phase1Cluster = 'CL-PHASE' }

        Get-PhaseRowValue -Row $row -PhaseColumn 'Phase1Cluster' -Default 'CL-DEFAULT' | Should -Be 'CL-PHASE'
    }

    It 'falls back to the run default when the cell is empty' {
        $row = [pscustomobject]@{ Phase1Cluster = '' }
        Get-PhaseRowValue -Row $row -PhaseColumn 'Phase1Cluster' -Default 'CL-DEFAULT' | Should -Be 'CL-DEFAULT'
    }

    It 'copes with a column the file does not have at all' {
        $row = [pscustomobject]@{ VMName = 'vm-a' }
        Get-PhaseRowValue -Row $row -PhaseColumn 'Phase2Datastore' -Default 'DS-DEFAULT' | Should -Be 'DS-DEFAULT'
    }
}

Describe 'Update-MigrationCsv' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
        $script:CsvPath = Join-Path $script:TestRoot 'wave1.csv'
        "VMName,Notes`nvm-a,keep me`nvm-b,and me" | Set-Content -LiteralPath $script:CsvPath
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'records the outcome on the right row and leaves the other one alone' {
        Update-MigrationCsv -Path $script:CsvPath -Update @(
            [pscustomobject]@{
                CsvLine = 2; PhaseCompleted = 1; CompletedAt = '2026-09-01 10:00:00'
                ResultVIServer = 'vc.corp.local'; ResultCluster = 'CL-NEW-01'
                ResultHost = 'esx-new-01'; ResultDatastore = 'DS-OLD-01'; ResultPortGroup = 'PG-NEW-Prod-100'
            }
        )

        $rows = @(Import-Csv -LiteralPath $script:CsvPath)
        $rows.Count | Should -Be 2

        $done = $rows | Where-Object { $_.VMName -eq 'vm-a' }
        $done.PhaseCompleted  | Should -Be '1'
        $done.ResultCluster   | Should -Be 'CL-NEW-01'
        $done.ResultPortGroup | Should -Be 'PG-NEW-Prod-100'
        $done.Notes           | Should -Be 'keep me'

        # The row that did not complete stays at 0 so a re-run picks it up.
        ($rows | Where-Object { $_.VMName -eq 'vm-b' }).PhaseCompleted | Should -Be '0'
    }

    It 'keeps the author columns and the row order' {
        Update-MigrationCsv -Path $script:CsvPath -Update @(
            [pscustomobject]@{ CsvLine = 3; PhaseCompleted = 1; CompletedAt = 'now' }
        )

        $rows = @(Import-Csv -LiteralPath $script:CsvPath)
        $rows[0].VMName | Should -Be 'vm-a'
        $rows[1].VMName | Should -Be 'vm-b'
        $rows[1].Notes  | Should -Be 'and me'
        # Every row carries every column that was written, so Export-Csv cannot drop one.
        $rows[0].PSObject.Properties.Name | Should -Contain 'PhaseCompleted'
        $rows[0].PSObject.Properties.Name | Should -Contain 'CompletedAt'
    }

    It 'does nothing when there is nothing to record' {
        $before = Get-Content -LiteralPath $script:CsvPath -Raw
        Update-MigrationCsv -Path $script:CsvPath -Update @()
        Get-Content -LiteralPath $script:CsvPath -Raw | Should -Be $before
    }

    It 'can be applied twice, the second phase overwriting the first' {
        Update-MigrationCsv -Path $script:CsvPath -Update @([pscustomobject]@{ CsvLine = 2; PhaseCompleted = 1; ResultDatastore = 'DS-OLD-01' })
        Update-MigrationCsv -Path $script:CsvPath -Update @([pscustomobject]@{ CsvLine = 2; PhaseCompleted = 2; ResultDatastore = 'DS-NEW-01' })

        $row = @(Import-Csv -LiteralPath $script:CsvPath) | Where-Object { $_.VMName -eq 'vm-a' }
        $row.PhaseCompleted  | Should -Be '2'
        $row.ResultDatastore | Should -Be 'DS-NEW-01'
    }
}

Describe 'Import-MigrationCsv phase column' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reads PhaseCompleted as a number and defaults it to 0' {
        $path = Join-Path $script:TestRoot 'phases.csv'
        "VMName,PhaseCompleted`nvm-a,2`nvm-b," | Set-Content -LiteralPath $path

        $rows = @(Import-MigrationCsv -Path $path)

        $rows[0].PhaseCompleted | Should -Be 2
        $rows[1].PhaseCompleted | Should -Be 0
    }

    It 'throws on a PhaseCompleted value that is not a phase' {
        $path = Join-Path $script:TestRoot 'bad-phase.csv'
        "VMName,PhaseCompleted`nvm-a,later" | Set-Content -LiteralPath $path

        { Import-MigrationCsv -Path $path } | Should -Throw '*invalid PhaseCompleted*'
    }
}

Describe 'Port group lists' {

    It 'parses adapter=portgroup pairs, whatever the spacing' {
        $map = ConvertFrom-PortGroupList -Value 'Network adapter 1=PG-Prod-100;Network adapter 2 = PG-Bkp-300 '

        $map.Count                     | Should -Be 2
        $map['Network adapter 1']      | Should -Be 'PG-Prod-100'
        $map['Network adapter 2']      | Should -Be 'PG-Bkp-300'
    }

    It 'treats a bare value as applying to every adapter' {
        (ConvertFrom-PortGroupList -Value 'PG-Solo')['*'] | Should -Be 'PG-Solo'
    }

    It 'returns an empty map for an empty cell' {
        (ConvertFrom-PortGroupList -Value '').Count  | Should -Be 0
        (ConvertFrom-PortGroupList -Value $null).Count | Should -Be 0
    }

    It 'renders the resolved mappings back into one cell' {
        $mappings = @(
            [pscustomobject]@{ AdapterName = 'Network adapter 1'; TargetName = 'PG-Prod-100' }
            [pscustomobject]@{ AdapterName = 'Network adapter 2'; TargetName = 'PG-Bkp-300' }
        )

        ConvertTo-PortGroupList -Mapping $mappings | Should -Be 'Network adapter 1=PG-Prod-100; Network adapter 2=PG-Bkp-300'
    }

    It 'round trips' {
        $mappings = @(
            [pscustomobject]@{ AdapterName = 'Network adapter 1'; TargetName = 'PG-A' }
            [pscustomobject]@{ AdapterName = 'Network adapter 2'; TargetName = 'PG-B' }
        )
        $map = ConvertFrom-PortGroupList -Value (ConvertTo-PortGroupList -Mapping $mappings)

        $map['Network adapter 1'] | Should -Be 'PG-A'
        $map['Network adapter 2'] | Should -Be 'PG-B'
    }

    It 'names the port group column for each phase' {
        Get-PhasePortGroupColumn -Phase 1 | Should -Be 'Phase1PortGroups'
        Get-PhasePortGroupColumn -Phase 2 | Should -BeNullOrEmpty
        Get-PhasePortGroupColumn -Phase 3 | Should -Be 'Phase3PortGroups'
    }
}

Describe 'Migration cost model' {

    BeforeAll {
        function New-CostPlan {
            param(
                [string]$VMName = 'vm-a',
                [string]$SourceHost = 'esx-01',
                [string]$TargetHost = 'esx-02',
                [string]$SourceDatastore = 'DS-A',
                [string]$TargetDatastore = 'DS-B',
                [switch]$Storage,
                [switch]$Compute
            )
            $plan = New-EmptyPlan -VMName $VMName
            $plan.SourceHost          = $SourceHost
            $plan.TargetHost          = [pscustomobject]@{ Name = $TargetHost }
            $plan.SourceDatastoreName = $SourceDatastore
            $plan.DatastoreName       = $TargetDatastore
            $plan.ChangesStorage      = [bool]$Storage
            $plan.ChangesCompute      = [bool]$Compute
            return $plan
        }
    }

    It 'costs a vMotion 1 on each host, 1 on the datastore and 1 on the network' {
        $cost = Get-MigrationCost -Plan (New-CostPlan -Compute)

        $cost.Hosts['esx-01']      | Should -Be 1
        $cost.Hosts['esx-02']      | Should -Be 1
        $cost.Datastores['DS-A']   | Should -Be 1
        $cost.Networks['esx-01']   | Should -Be 1
        $cost.Networks['esx-02']   | Should -Be 1
    }

    It 'costs a Storage vMotion 4 on the host and 16 against each datastore' {
        $cost = Get-MigrationCost -Plan (New-CostPlan -Storage -TargetHost 'esx-01')

        $cost.Hosts['esx-01']    | Should -Be 4
        $cost.Datastores['DS-A'] | Should -Be 16
        $cost.Datastores['DS-B'] | Should -Be 16
        # A Storage vMotion does not use the vMotion network.
        $cost.Networks.Count     | Should -Be 0
    }

    It 'costs nothing when there is nothing to move' {
        (Get-MigrationCost -Plan (New-CostPlan)).IsFree | Should -BeTrue
    }

    It 'allows 8 vMotions on a host and holds the 9th' {
        $ledger = New-MigrationCostLedger
        for ($i = 1; $i -le 8; $i++) {
            $cost = Get-MigrationCost -Plan (New-CostPlan -VMName "vm-$i" -SourceHost 'esx-01' -TargetHost "esx-spread-$i" -Compute)
            (Test-MigrationAdmission -Ledger $ledger -Cost $cost).Allowed | Should -BeTrue
            Add-MigrationCost -Ledger $ledger -Cost $cost
        }

        $ninth = Get-MigrationCost -Plan (New-CostPlan -VMName 'vm-9' -SourceHost 'esx-01' -TargetHost 'esx-spread-9' -Compute)
        $verdict = Test-MigrationAdmission -Ledger $ledger -Cost $ninth
        $verdict.Allowed | Should -BeFalse
        $verdict.Reason  | Should -Match "host 'esx-01' is at 8 of 8"
    }

    It 'allows 2 Storage vMotions on a host and holds the 3rd until one finishes' {
        $ledger = New-MigrationCostLedger

        $first  = Get-MigrationCost -Plan (New-CostPlan -VMName 'vm-1' -SourceHost 'esx-01' -TargetHost 'esx-01' -TargetDatastore 'DS-1' -Storage)
        $second = Get-MigrationCost -Plan (New-CostPlan -VMName 'vm-2' -SourceHost 'esx-01' -TargetHost 'esx-01' -TargetDatastore 'DS-2' -Storage)
        $third  = Get-MigrationCost -Plan (New-CostPlan -VMName 'vm-3' -SourceHost 'esx-01' -TargetHost 'esx-01' -TargetDatastore 'DS-3' -Storage)

        Add-MigrationCost -Ledger $ledger -Cost $first
        Add-MigrationCost -Ledger $ledger -Cost $second

        (Test-MigrationAdmission -Ledger $ledger -Cost $third).Allowed | Should -BeFalse

        # One finishes and the third can go.
        Remove-MigrationCost -Ledger $ledger -Cost $first
        (Test-MigrationAdmission -Ledger $ledger -Cost $third).Allowed | Should -BeTrue
    }

    It 'allows 8 Storage vMotions against one datastore and holds the 9th' {
        $ledger = New-MigrationCostLedger

        for ($i = 1; $i -le 8; $i++) {
            $cost = Get-MigrationCost -Plan (New-CostPlan -VMName "vm-$i" -SourceHost "esx-$i" -TargetHost "esx-$i" -SourceDatastore "DS-src-$i" -TargetDatastore 'DS-SHARED' -Storage)
            (Test-MigrationAdmission -Ledger $ledger -Cost $cost).Allowed | Should -BeTrue
            Add-MigrationCost -Ledger $ledger -Cost $cost
        }

        $ninth = Get-MigrationCost -Plan (New-CostPlan -VMName 'vm-9' -SourceHost 'esx-9' -TargetHost 'esx-9' -SourceDatastore 'DS-src-9' -TargetDatastore 'DS-SHARED' -Storage)
        $verdict = Test-MigrationAdmission -Ledger $ledger -Cost $ninth
        $verdict.Allowed | Should -BeFalse
        $verdict.Reason  | Should -Match "datastore 'DS-SHARED' is at 128 of 128"
    }

    It 'binds on the vMotion network at 4 on a 1GigE estate' {
        $ledger = New-MigrationCostLedger -NetworkMaximum 4

        for ($i = 1; $i -le 4; $i++) {
            $cost = Get-MigrationCost -Plan (New-CostPlan -VMName "vm-$i" -SourceHost 'esx-01' -TargetHost "esx-dest-$i" -Compute)
            Add-MigrationCost -Ledger $ledger -Cost $cost
        }

        $fifth = Get-MigrationCost -Plan (New-CostPlan -VMName 'vm-5' -SourceHost 'esx-01' -TargetHost 'esx-dest-5' -Compute)
        $verdict = Test-MigrationAdmission -Ledger $ledger -Cost $fifth

        # The host limit is 8, so it is the network that stops this one.
        $verdict.Allowed | Should -BeFalse
        $verdict.Reason  | Should -Match 'vMotion network'
    }

    It 'releases capacity when a migration finishes' {
        $ledger = New-MigrationCostLedger
        $cost = Get-MigrationCost -Plan (New-CostPlan -SourceHost 'esx-01' -TargetHost 'esx-01' -Storage)

        Add-MigrationCost -Ledger $ledger -Cost $cost
        $ledger.HostCost['esx-01'] | Should -Be 4

        Remove-MigrationCost -Ledger $ledger -Cost $cost
        $ledger.HostCost['esx-01'] | Should -Be 0
    }

    It 'counts another engineer''s migrations against the same host budget' {
        $ledger = New-MigrationCostLedger
        # Two Storage vMotions someone else started have used the host's whole budget.
        $ledger.ExternalHost['esx-01'] = 8

        $cost = Get-MigrationCost -Plan (New-CostPlan -SourceHost 'esx-01' -TargetHost 'esx-02' -Compute)
        (Test-MigrationAdmission -Ledger $ledger -Cost $cost).Allowed | Should -BeFalse
    }
}

Describe 'Wave state' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        $script:InDir      = Join-Path $script:TestRoot 'IN'
        $script:RunningDir = Join-Path $script:TestRoot 'Running'
        New-Item -ItemType Directory -Path $script:InDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:RunningDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lists a fresh wave as ready for phase 1' {
        "VMName`nvm-a`nvm-b" | Set-Content -LiteralPath (Join-Path $script:InDir 'wave1.csv')

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -Phase 1)

        $wave.Count       | Should -Be 1
        $wave[0].State    | Should -Be 'Ready'
        $wave[0].VMCount  | Should -Be 2
        $wave[0].NextPhase | Should -Be 1
        $wave[0].Selectable | Should -BeTrue
    }

    It 'marks a wave due for another phase as not selectable' {
        "VMName,PhaseCompleted`nvm-a,1" | Set-Content -LiteralPath (Join-Path $script:InDir 'wave1.csv')

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -Phase 1)[0]

        $wave.State       | Should -Be 'NotDue'
        $wave.StateDetail | Should -Match 'due for phase 2'
        $wave.Selectable  | Should -BeFalse
    }

    It 'reports a wave another live run has claimed as busy' {
        $csv = Join-Path $script:RunningDir 'wave1.csv'
        "VMName`nvm-a" | Set-Content -LiteralPath $csv
        Write-WaveRunMarker -CsvPath $csv -Phase 1 | Out-Null

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -Phase 1)[0]

        # The marker names this very process, so the run is alive.
        $wave.State      | Should -Be 'Busy'
        $wave.Selectable | Should -BeFalse
        $wave.StateDetail | Should -Match $env:USERNAME
    }

    It 'reports a wave whose run has died as interrupted and resumable' {
        $csv = Join-Path $script:RunningDir 'wave1.csv'
        "VMName`nvm-a" | Set-Content -LiteralPath $csv
        Write-WaveRunMarker -CsvPath $csv -Phase 1 | Out-Null

        # Point the marker at a process id that cannot be running.
        $markerPath = Get-WaveRunMarkerPath -CsvPath $csv
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $marker.ProcessId = 999999
        $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -Phase 1)[0]

        $wave.State       | Should -Be 'Interrupted'
        $wave.StateDetail | Should -Match 'the process is gone'
        $wave.Selectable  | Should -BeTrue
    }

    It 'spots a recycled process id rather than believing the run is alive' {
        $csv = Join-Path $script:RunningDir 'wave1.csv'
        "VMName`nvm-a" | Set-Content -LiteralPath $csv
        Write-WaveRunMarker -CsvPath $csv -Phase 1 | Out-Null

        # Same (live) process id, but the process started at a different time.
        $markerPath = Get-WaveRunMarkerPath -CsvPath $csv
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $marker.ProcessStartedAt = (Get-Date).AddDays(-3).ToString('o')
        $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath

        (Test-WaveRunAlive -Marker (Read-WaveRunMarker -CsvPath $csv)).Alive | Should -BeFalse
    }

    It 'assumes a wave claimed from another machine is still running' {
        $csv = Join-Path $script:RunningDir 'wave1.csv'
        "VMName`nvm-a" | Set-Content -LiteralPath $csv
        Write-WaveRunMarker -CsvPath $csv -Phase 1 | Out-Null

        $markerPath = Get-WaveRunMarkerPath -CsvPath $csv
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $marker.Machine   = 'OTHER-MGMT-01'
        $marker.ProcessId = 999999
        $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath

        $alive = Test-WaveRunAlive -Marker (Read-WaveRunMarker -CsvPath $csv)
        $alive.Alive  | Should -BeTrue
        $alive.Reason | Should -Match 'OTHER-MGMT-01'
    }

    It 'lists a wave waiting in Phase1 as due for phase 2' {
        $phase1 = Join-Path $script:TestRoot 'Phase1'
        New-Item -ItemType Directory -Path $phase1 -Force | Out-Null
        "VMName,PhaseCompleted`nvm-a,1" | Set-Content -LiteralPath (Join-Path $phase1 'wave1.csv')

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -ArchiveRoot $script:TestRoot -Phase 2)

        # No file was moved to get here - it is offered from where phase 1 left it.
        $wave.Count        | Should -Be 1
        $wave[0].NextPhase | Should -Be 2
        $wave[0].State     | Should -Be 'Ready'
        $wave[0].Selectable | Should -BeTrue
    }

    It 'does not list waves that have finished phase 3' {
        $phase3 = Join-Path $script:TestRoot 'Phase3'
        New-Item -ItemType Directory -Path $phase3 -Force | Out-Null
        "VMName,PhaseCompleted`nvm-a,3" | Set-Content -LiteralPath (Join-Path $phase3 'done.csv')

        @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -ArchiveRoot $script:TestRoot).Count |
            Should -Be 0
    }

    It 'counts how many rows are already through the phase the wave is due for' {
        "VMName,PhaseCompleted`nvm-a,1`nvm-b,1`nvm-c,0" | Set-Content -LiteralPath (Join-Path $script:InDir 'part.csv')

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -Phase 1)[0]

        $wave.NextPhase | Should -Be 1
        $wave.VMCount   | Should -Be 3
        $wave.DoneCount | Should -Be 2
    }

    It 'reports a wave that cannot be read as invalid rather than throwing' {
        "Name,Cluster`nvm-a,CL" | Set-Content -LiteralPath (Join-Path $script:InDir 'broken.csv')

        $wave = @(Get-AvailableWave -InFolder $script:InDir -RunningFolder $script:RunningDir -Phase 1)[0]

        $wave.State      | Should -Be 'Invalid'
        $wave.Selectable | Should -BeFalse
    }

    It 'releases a wave into the phase folder and removes the marker' {
        $csv = Join-Path $script:RunningDir 'wave1.csv'
        "VMName`nvm-a" | Set-Content -LiteralPath $csv
        Write-WaveRunMarker -CsvPath $csv -Phase 1 | Out-Null

        $destination = Join-Path $script:TestRoot 'Phase1'
        $landed = Complete-WaveRun -Path $csv -Destination $destination

        Test-Path -LiteralPath $landed | Should -BeTrue
        Test-Path -LiteralPath $csv    | Should -BeFalse
        Test-Path -LiteralPath (Get-WaveRunMarkerPath -CsvPath $csv) | Should -BeFalse
    }
}

Describe 'Credentials' {

    BeforeEach {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bvm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
        $script:PreviousHome = $env:BVM_CREDENTIAL_HOME
        $env:BVM_CREDENTIAL_HOME = $script:TestRoot
    }

    AfterEach {
        $env:BVM_CREDENTIAL_HOME = $script:PreviousHome
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps each vCenter under the engineer''s own profile' {
        $path = Get-MigrationCredentialPath -VIServer 'VC-Old.Corp.Local'

        $path | Should -BeLike (Join-Path $script:TestRoot '*')
        # The name is normalised, so casing cannot produce two files for one vCenter.
        [System.IO.Path]::GetFileName($path) | Should -Be 'vc-old.corp.local.cred.xml'
    }

    It 'uses the credential passed on the command line ahead of anything stored' {
        $explicit = [pscredential]::new('DOMAIN\alice', (ConvertTo-SecureString 'pw' -AsPlainText -Force))

        (Get-MigrationCredential -VIServer 'vc.corp.local' -Credential $explicit).UserName | Should -Be 'DOMAIN\alice'
    }

    It 'returns nothing rather than prompting when told not to prompt' {
        Get-MigrationCredential -VIServer 'vc.corp.local' -NoPrompt | Should -BeNullOrEmpty
    }

    It 'refuses to store a credential where the password would not be encrypted' {
        # Export-Clixml only encrypts a SecureString on Windows, so the guard only has
        # anything to do elsewhere. The check runs here, not at discovery time, because
        # the module is not loaded yet when Pester evaluates -Skip.
        if (Test-IsWindowsPlatform) {
            Set-ItResult -Skipped -Because 'the guard only applies off Windows'
            return
        }

        $credential = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))

        { Save-MigrationCredential -VIServer 'vc.corp.local' -Credential $credential } |
            Should -Throw '*only be stored on Windows*'
    }
}

Describe 'Show-WavePicker' {

    BeforeAll {
        function New-PickerWave {
            param([string]$Name, [string]$State = 'Ready', [bool]$Selectable = $true, [int]$NextPhase = 1)
            [pscustomobject]@{
                Name = $Name; Path = "/tmp/$Name"; VMCount = 3; NextPhase = $NextPhase
                State = $State; StateDetail = ''; Selectable = $Selectable
            }
        }
    }

    It 'returns the wave whose number the engineer typed' {
        Mock -ModuleName BulkVMotion Read-Host { '2' }

        $chosen = Show-WavePicker -Phase 1 -Wave @(
            (New-PickerWave -Name 'wave1.csv'), (New-PickerWave -Name 'wave2.csv')
        )

        $chosen.Name | Should -Be 'wave2.csv'
    }

    It 'numbers only the waves that can be run' {
        # wave1 is busy, so typing 1 has to pick wave2.
        Mock -ModuleName BulkVMotion Read-Host { '1' }

        $chosen = Show-WavePicker -Phase 1 -Wave @(
            (New-PickerWave -Name 'wave1.csv' -State 'Busy' -Selectable $false)
            (New-PickerWave -Name 'wave2.csv')
        )

        $chosen.Name | Should -Be 'wave2.csv'
    }

    It 'returns nothing when the engineer quits' {
        Mock -ModuleName BulkVMotion Read-Host { 'Q' }

        Show-WavePicker -Phase 1 -Wave @((New-PickerWave -Name 'wave1.csv')) | Should -BeNullOrEmpty
    }

    It 'asks again after an answer that is not a listed number' {
        $script:answers = @('99', 'nonsense', '1')
        $script:index = 0
        Mock -ModuleName BulkVMotion Read-Host { $value = $script:answers[$script:index]; $script:index++; $value }

        $chosen = Show-WavePicker -Phase 1 -Wave @((New-PickerWave -Name 'wave1.csv'))

        $chosen.Name    | Should -Be 'wave1.csv'
        $script:index   | Should -Be 3
    }

    It 'returns nothing when there is nothing runnable' {
        Show-WavePicker -Phase 1 -Wave @((New-PickerWave -Name 'wave1.csv' -State 'Busy' -Selectable $false)) |
            Should -BeNullOrEmpty
    }

    It 'returns nothing when there are no waves at all' {
        Show-WavePicker -Phase 1 -Wave @() | Should -BeNullOrEmpty
    }
}
