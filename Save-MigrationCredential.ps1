<#
.SYNOPSIS
    Stores a vCenter credential for the engineer running this, on this machine.

.DESCRIPTION
    Several VMware engineers share the mgmt server, so credentials are kept per
    engineer rather than in a config file. The password is protected with DPAPI,
    tied to this Windows account on this machine: a colleague logged into the same
    server cannot decrypt it, and the file is useless if copied elsewhere.

    Run it once per vCenter. Invoke-BulkVMotion.ps1 then picks the credential up on
    its own, and prompts only if there is nothing stored.

.PARAMETER VIServer
    The vCenter this credential is for. Use the same name you pass to
    -SourceVIServer / -TargetVIServer, so the run can find it.

.PARAMETER Credential
    Supply the credential instead of being prompted for it.

.PARAMETER Remove
    Delete the stored credential for this vCenter instead of saving one.

.EXAMPLE
    .\Save-MigrationCredential.ps1 -VIServer vc.corp.local

    Prompts for the username and password and stores them for you.

.EXAMPLE
    .\Save-MigrationCredential.ps1 -VIServer vc-new.corp.local -Remove

    Forgets the stored credential for the new vCenter.

.NOTES
    Windows only. On Linux and macOS PowerShell does not encrypt a SecureString, so
    saving is refused rather than writing your password to disk in the clear.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'An engineer runs this at a console to set themselves up; telling them what happened is the whole output.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$VIServer,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path (Join-Path (Join-Path $scriptRoot 'Modules') 'BulkVMotion') 'BulkVMotion.psd1') -Force

$path = Get-MigrationCredentialPath -VIServer $VIServer

if ($Remove) {
    if (Test-Path -LiteralPath $path) {
        if ($PSCmdlet.ShouldProcess($path, 'Delete the stored credential')) {
            Remove-Item -LiteralPath $path -Force
        }
        Write-Host "Removed the stored credential for $VIServer." -ForegroundColor Green
    }
    else {
        Write-Host "There is no stored credential for $VIServer." -ForegroundColor Yellow
    }
    return
}

if (-not (Test-IsWindowsPlatform)) {
    throw 'Credentials can only be stored on Windows: on Linux and macOS, Export-Clixml does not encrypt the password. Pass -SourceCredential/-TargetCredential to the run instead, or let it prompt.'
}

if (-not $Credential) {
    $Credential = Get-Credential -Message "Credentials for $VIServer"
}
if (-not $Credential) {
    throw 'No credential was supplied.'
}

$saved = Save-MigrationCredential -VIServer $VIServer -Credential $Credential

Write-Host ''
Write-Host "Stored the credential for $VIServer as $($Credential.UserName)." -ForegroundColor Green
Write-Host "  File : $saved"
Write-Host "  It is encrypted to $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME - nobody else can read it, and it will not work on another machine."
Write-Host ''
