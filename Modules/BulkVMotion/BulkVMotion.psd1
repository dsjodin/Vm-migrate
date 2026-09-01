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
        'Get-PortGroupVlanInfo'
        'Get-VlanPortGroupMap'
        'Write-VlanPortGroupMapReport'
        'Resolve-TargetPortGroup'
        'Import-PortGroupExceptionMap'
        'Resolve-SourceVM'
        'Select-TargetVMHost'
        'Resolve-TargetDatastore'
        'Test-VMOnTargetDatastore'
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('VMware', 'PowerCLI', 'vMotion', 'Migration', 'VDS')
        }
    }
}
