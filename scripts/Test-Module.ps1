#Requires -Version 5.1
<#
.SYNOPSIS
Validate the module and run deterministic offline tests; never install dependencies.
.PARAMETER TestPath
Optional subset of Pester test files. Defaults to all tests.
.PARAMETER ResultPath
Optional NUnit XML result file.
.PARAMETER CodeCoverage
Measure module source coverage with Pester.
#>
[CmdletBinding()]
param(
    [string[]] $TestPath,
    [string] $ResultPath,
    [switch] $CodeCoverage
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
Import-Module Pester -RequiredVersion $dependencies.Pester
Import-Module PSScriptAnalyzer -RequiredVersion $dependencies.PSScriptAnalyzer
$manifestPath = Join-Path $root 'FabricCapacityOverage\FabricCapacityOverage.psd1'
$null = Test-ModuleManifest -Path $manifestPath
Import-Module $manifestPath
$exports = @(Get-Command -Module FabricCapacityOverage)
if ($exports.Count -ne 1 -or $exports[0].Name -ne 'Get-FabricCapacityOverageCost') {
    throw 'The module must export exactly Get-FabricCapacityOverageCost.'
}
if ((Get-Help Get-FabricCapacityOverageCost).Synopsis -notmatch 'Estimates additional Fabric') {
    throw 'The exported function must expose its comment-based help.'
}
$findings = @(foreach ($relativePath in @('FabricCapacityOverage', 'Get-FabricCapacityOverageCost.ps1', 'scripts', 'tests', 'examples')) {
    Invoke-ScriptAnalyzer -Path (Join-Path $root $relativePath) -Recurse
})
if ($findings.Count -gt 0) {
    $findings | Format-Table RuleName, Severity, ScriptName, Line, Message -Wrap | Out-Host
    throw "ScriptAnalyzer reported $($findings.Count) unsuppressed findings."
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = if ($TestPath.Count -gt 0) {
    $TestPath
}
else {
    @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.Tests.ps1' -File | Select-Object -ExpandProperty FullName)
}
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $ResultPath
    $configuration.TestResult.OutputFormat = 'NUnitXml'
}
if ($CodeCoverage) {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.build') -Force
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = @(Join-Path $root 'FabricCapacityOverage\Private\*.ps1'; Join-Path $root 'FabricCapacityOverage\Public\*.ps1')
    $configuration.CodeCoverage.OutputPath = Join-Path $root '.build\coverage.xml'
}
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.TotalCount -eq 0) {
    throw "Pester failed: $($result.FailedCount) failures out of $($result.TotalCount) tests."
}
$result
