#Requires -Version 7.4
<#
.SYNOPSIS
Build and inspect an offline package and import it from a disposable installation.
.DESCRIPTION
Does not register repositories, install into normal module directories, sign,
publish, authenticate or call Fabric/Power BI. Uses PSResourceGet for packaging
and Pester TestDrive for the extracted versioned module installation.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $DestinationPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.build\packages')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
Import-Module Pester -RequiredVersion $dependencies.Pester
$package = & (Join-Path $PSScriptRoot 'Build-Package.ps1') -DestinationPath $DestinationPath
$containers = @(New-PesterContainer -Path (Join-Path $root 'tests\Packaging\Package.Tests.ps1') -Data @{
    PackagePath = $package.FullName
    ManifestPath = Join-Path $root 'FabricCapacityOverage\FabricCapacityOverage.psd1'
})
$containers += New-PesterContainer -Path (Join-Path $root 'tests\Packaging\ReleasePackage.Tests.ps1') -Data @{
    ManifestPath = Join-Path $root 'FabricCapacityOverage\FabricCapacityOverage.psd1'
}
$configuration = New-PesterConfiguration
$configuration.Run.Path = @()
$configuration.Run.Container = $containers
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.TotalCount -eq 0) {
    throw "Package validation failed: $($result.FailedCount) failures out of $($result.TotalCount) tests."
}
[pscustomobject] @{ PackagePath = $package.FullName; TestsPassed = $result.PassedCount }
