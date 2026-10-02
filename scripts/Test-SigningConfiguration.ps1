#Requires -Version 7.4
[CmdletBinding()]
param([switch] $ReadAzureResources)

& ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-DevelopmentEnvironment.ps1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release\Release.Helpers.ps1')
$null = Get-ReleaseContext -Environment (Get-ReleaseEnvironment) -Workflow 'sign-module.yml'
$configuration = Get-ReleaseSigningConfiguration (Get-ReleaseSigningEnvironment)
if ($ReadAzureResources) {
    $account = Invoke-ReleaseAzureRead -ResourceId $configuration.AccountId
    $certificateProfile = Invoke-ReleaseAzureRead -ResourceId $configuration.ProfileId
    Test-ReleaseSigningResource -Configuration $configuration -Account $account -CertificateProfile $certificateProfile
}
