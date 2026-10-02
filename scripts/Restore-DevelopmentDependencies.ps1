#Requires -Version 7.4
[CmdletBinding()]
param([ValidateSet('Validation', 'Publishing')] [string] $Purpose = 'Validation')

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'Automatic development-tool restoration is limited to an ephemeral GitHub Actions runner.'
}
$cache = Join-Path $env:RUNNER_TEMP 'overage-development-modules'
$null = New-Item -ItemType Directory -Path $cache -Force
$dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
$names = if ($Purpose -eq 'Publishing') { @('Microsoft.PowerShell.PSResourceGet') } else { @($dependencies.Keys) }
foreach ($name in $names) {
    Save-PSResource -Name $name -Version $dependencies[$name] -Repository PSGallery -Path $cache -TrustRepository -Quiet -ErrorAction Stop
}
if ($Purpose -eq 'Validation') {
    $manifest = Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'FabricCapacityOverage\FabricCapacityOverage.psd1')
    foreach ($dependency in $manifest.RequiredModules) {
        Save-PSResource -Name $dependency.ModuleName -Version $dependency.ModuleVersion -Repository PSGallery -Path $cache -TrustRepository -Quiet -ErrorAction Stop
    }
}
[System.IO.File]::AppendAllText($env:GITHUB_ENV, "PSModulePath=$cache;$env:PSModulePath`n", [System.Text.UTF8Encoding]::new($false))
