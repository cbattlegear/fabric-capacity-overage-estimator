#Requires -Version 7.4
<#
.SYNOPSIS
Build an offline module package with PSResourceGet; never sign or publish.
.DESCRIPTION
Validates the manifest and compresses only the shipped module folder, including
its MIT license. The destination must be outside the module source directory.
Defaults to unsigned source. The manual release pipeline passes an already
verified signed staging ModulePath; packaging does not modify those bytes.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $DestinationPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.build\packages'),

    [ValidateNotNullOrEmpty()]
    [string] $ModulePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'FabricCapacityOverage')
)

$ErrorActionPreference = 'Stop'
$dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
Import-Module Microsoft.PowerShell.PSResourceGet -RequiredVersion $dependencies.'Microsoft.PowerShell.PSResourceGet'
$modulePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ModulePath)
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
$source = [System.IO.Path]::GetFullPath($modulePath).TrimEnd('\') + '\'
if ($destination.StartsWith($source, [System.StringComparison]::OrdinalIgnoreCase) -or
    $destination.TrimEnd('\') -eq $source.TrimEnd('\')) {
    throw 'Package output must be outside the module source folder.'
}
$null = Test-ModuleManifest -Path (Join-Path $modulePath 'FabricCapacityOverage.psd1')
$null = New-Item -ItemType Directory -Path $destination -Force
Compress-PSResource -Path $modulePath -DestinationPath $destination -PassThru
