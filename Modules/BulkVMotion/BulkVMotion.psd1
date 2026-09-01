@{
    RootModule        = 'BulkVMotion.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7c1f2ac-1d6f-4a2e-9a55-3d5d2f9c4e11'
    Author            = 'Platform Operations'
    Description       = 'Helper functions for CSV driven bulk cross-cluster / cross-vCenter vMotion with VLAN based VDS port group remapping.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Start-BulkVMotionLog'
        'Stop-BulkVMotionLog'
        'Write-BulkVMotionLog'
        'Get-BulkVMotionLogFile'
        'Import-MigrationCsv'
        'Move-ProcessedCsv'
        'Test-IsWindowsPlatform'
        'Get-MigrationCredentialPath'
        'Save-MigrationCredential'
        'Get-MigrationCredential'
        'Get-WaveRunMarkerPath'
        'Write-WaveRunMarker'
        'Read-WaveRunMarker'
        'Test-WaveRunAlive'
        'Get-AvailableWave'
        'Show-WavePicker'
        'Start-WaveRun'
        'Complete-WaveRun'
        'Get-CsvNextPhase'
        'Get-PhaseRowValue'
        'Get-PhasePortGroupColumn'
        'ConvertFrom-PortGroupList'
        'ConvertTo-PortGroupList'
        'New-MigrationCostLedger'
        'Get-MigrationCost'
        'Test-MigrationAdmission'
        'Add-MigrationCost'
        'Remove-MigrationCost'
        'Update-ExternalMigrationCost'
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
        'Get-TargetSwitchContext'
        'Get-VMNetworkMigrationPlan'
        'New-VMMigrationPlan'
        'Write-MigrationPlanReport'
        'Start-VMMigrationTask'
        'Wait-VMMigrationTask'
        'New-EmptyPlan'
        'New-MigrationTracker'
        'ConvertTo-MigrationResult'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('VMware', 'PowerCLI', 'vMotion', 'Migration', 'VDS')
        }
    }
}
