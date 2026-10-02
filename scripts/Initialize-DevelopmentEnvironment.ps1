#Requires -Version 5.1
<#
.SYNOPSIS
Initialize an edition-native module path with the optional isolated dependency cache.
.DESCRIPTION
Changes only this process. Does not restore/install tools or change profiles,
repositories or execution policies. Safe before any Utility/Management imports,
including Windows PowerShell children that inherit a PowerShell 7 environment.
#>
[CmdletBinding()]
param()

$nativeHome = [System.IO.Path]::GetFullPath($PSHOME)
$nativeModules = [System.IO.Path]::Combine($nativeHome, 'Modules')
$cache = [Environment]::GetEnvironmentVariable('FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE', 'Process')
if (-not [string]::IsNullOrWhiteSpace($cache)) {
    if (-not [System.IO.Path]::IsPathRooted($cache) -or $cache -match '[;\r\n]' -or
        -not [System.IO.Directory]::Exists($cache)) {
        throw 'FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE must identify an existing absolute dependency directory.'
    }
    $cache = [System.IO.Path]::GetFullPath($cache)
}

$scopeName = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'WindowsPowerShell' } else { 'PowerShell' }
$documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$candidates = @($nativeModules, $cache)
if (-not [string]::IsNullOrWhiteSpace($documents)) {
    $candidates += [System.IO.Path]::Combine($documents, $scopeName, 'Modules')
}
if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
    $candidates += [System.IO.Path]::Combine($programFiles, $scopeName, 'Modules')
}
$candidates += [Environment]::GetEnvironmentVariable('PSModulePath', 'Process') -split [System.IO.Path]::PathSeparator
$paths = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $path = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
    if (-not [string]::Equals($path, $nativeModules, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Remove inherited peer-edition built-ins, even from nonstandard PSHOME
        # installations, while keeping ordinary/custom dependency directories.
        $peerBuiltins = $false
        foreach ($name in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Management')) {
            if ([System.IO.File]::Exists([System.IO.Path]::Combine($path, $name, "$name.psd1"))) {
                $peerBuiltins = $true
                break
            }
        }
        if ($peerBuiltins) {
            if ([string]::Equals($path, $cache, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'The isolated dependency cache must not contain PowerShell built-in modules.'
            }
            continue
        }
    }
    if ($seen.Add($path)) { $paths.Add($path) }
}
$env:PSModulePath = [string]::Join([System.IO.Path]::PathSeparator, $paths)

foreach ($name in @('Microsoft.PowerShell.Utility\Import-PowerShellDataFile', 'Microsoft.PowerShell.Security\Get-AuthenticodeSignature')) {
    $null = Get-Command -Name $name -ErrorAction Stop
    $moduleName = $name.Split('\')[0]
    $module = Get-Module -Name $moduleName -ErrorAction Stop
    if ($null -eq $module -or (
        -not [string]::Equals($module.ModuleBase, $nativeHome, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $module.ModuleBase.StartsWith($nativeModules + '\', [System.StringComparison]::OrdinalIgnoreCase)
    )) {
        throw "Required built-in '$name' did not resolve from this host's native PSHOME modules."
    }
}
