#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release\Release.Helpers.ps1')
$context = Get-ReleaseContext -Environment (Get-ReleaseEnvironment) -Workflow 'sign-module.yml'
$configuration = Get-ReleaseSigningConfiguration (Get-ReleaseSigningEnvironment)
$info = Get-ReleaseModuleInfo (Get-Content -LiteralPath (Join-Path (Get-ReleaseSourceModule) 'FabricCapacityOverage.psd1') -Raw)
$root = Get-ReleaseWorkRoot $context
$stage = Join-Path $root 'module\FabricCapacityOverage'
$signed = @(Test-ReleaseModuleSignature -Root $stage -ModuleInfo $info -ExpectedSubject $configuration.Subject)
$package = & (Join-Path $PSScriptRoot 'Build-Package.ps1') -ModulePath $stage -DestinationPath (Join-Path $root 'packages')
$verified = Get-VerifiedReleasePackage -PackagePath $package.FullName -ModuleInfo $info -ExpectedSubject $configuration.Subject -ExtractionRoot (Join-Path $root 'verified-package') -Confirm:$false
foreach ($file in $verified.Files) {
    $matching = @($signed | Where-Object Path -CEQ $file.Path)
    if ($matching.Count -ne 1 -or $matching[0].SHA256 -cne $file.SHA256) {
        throw 'Packaging changed the exact signed staging bytes.'
    }
}
$after = @(Get-ReleaseFileInventory -Root $stage -ModuleInfo $info)
foreach ($file in $after) {
    if (@($signed | Where-Object { $_.Path -ceq $file.Path -and $_.SHA256 -ceq $file.SHA256 }).Count -ne 1) {
        throw 'The signed staging tree changed during packaging.'
    }
}
$provenance = Get-ReleaseProvenance -Context $context -ModuleInfo $info -Subject $configuration.Subject -Package $verified
$bundle = Join-Path $root 'signed-bundle'
Write-ReleaseBundle -Destination $bundle -Provenance $provenance -PackagePath $package.FullName -Confirm:$false
Write-ReleaseOutput -Name 'bundle_path' -Value $bundle
Write-ReleaseOutput -Name 'module_version' -Value $info.Version
Write-ReleaseOutput -Name 'package_sha' -Value $verified.PackageSHA256
