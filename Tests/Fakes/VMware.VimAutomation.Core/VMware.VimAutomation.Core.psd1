@{
    RootModule        = 'VMware.VimAutomation.Core.psm1'
    ModuleVersion     = '13.0.0'
    GUID              = 'a1f3c9d2-5b44-4c81-9f0e-8c2d61b7e002'
    Author            = 'Tests'
    Description       = 'Test double for VMware.VimAutomation.Core - not the real PowerCLI module.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Connect-VIServer', 'Disconnect-VIServer', 'Set-PowerCLIConfiguration',
        'Get-VM', 'Get-NetworkAdapter', 'Get-VirtualPortGroup', 'Get-Cluster', 'Get-VMHost',
        'Get-Datastore', 'Get-DatastoreCluster', 'Get-Folder', 'Move-VM', 'Get-Task')
}
