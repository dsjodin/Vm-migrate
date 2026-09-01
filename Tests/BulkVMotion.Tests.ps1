<#
    Unit tests for the parts of BulkVMotion that do not need a vCenter connection:
    VLAN parsing, port group matching, CSV validation and the CSV archive move.

    Run with:  Invoke-Pester -Path .\Tests
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper names read better in the plural.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build fixtures; there is nothing to confirm.')]
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
        "VMName,TargetCluster`nvm-app-01,CL-NEW-01`nvm-app-02,CL-NEW-01" | Set-Content -LiteralPath $path

        $rows = @(Import-MigrationCsv -Path $path)

        $rows.Count              | Should -Be 2
        $rows[0].VMName          | Should -Be 'vm-app-01'
        $rows[0].TargetCluster   | Should -Be 'CL-NEW-01'
        $rows[0].TargetDatastore | Should -Be ''
        $rows[0].CsvLine         | Should -Be 2
        $rows[1].CsvLine         | Should -Be 3
    }

    It 'trims whitespace around values' {
        $path = Join-Path $script:TestRoot 'spaces.csv'
        "VMName,TargetCluster`n  vm-app-01  ,  CL-NEW-01  " | Set-Content -LiteralPath $path

        (Import-MigrationCsv -Path $path).VMName | Should -Be 'vm-app-01'
    }

    It 'throws when the VMName column is missing' {
        $path = Join-Path $script:TestRoot 'bad.csv'
        "Name,TargetCluster`nvm-app-01,CL-NEW-01" | Set-Content -LiteralPath $path

        { Import-MigrationCsv -Path $path } | Should -Throw '*missing required column*'
    }

    It 'throws when the file has no data rows' {
        $path = Join-Path $script:TestRoot 'empty.csv'
        'VMName,TargetCluster' | Set-Content -LiteralPath $path

        { Import-MigrationCsv -Path $path } | Should -Throw '*no data rows*'
    }

    It 'throws when the file does not exist' {
        { Import-MigrationCsv -Path (Join-Path $script:TestRoot 'nope.csv') } | Should -Throw '*not found*'
    }

    It 'skips rows with an empty VMName' {
        $path = Join-Path $script:TestRoot 'gap.csv'
        "VMName,TargetCluster`nvm-app-01,CL-NEW-01`n,CL-NEW-01" | Set-Content -LiteralPath $path

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
