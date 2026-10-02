#Requires -Version 7.4
[CmdletBinding()]
param()

& ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-DevelopmentEnvironment.ps1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release\Release.Helpers.ps1')
$context = Get-ReleaseContext -Environment (Get-ReleaseEnvironment) -Workflow 'sign-module.yml'
$null = Get-ReleaseSigningConfiguration (Get-ReleaseSigningEnvironment)
$source = Get-ReleaseSourceModule
$info = Get-ReleaseModuleInfo (Get-Content -LiteralPath (Join-Path $source 'FabricCapacityOverage.psd1') -Raw)
$workRoot = Get-ReleaseWorkRoot $context
$stage = Join-Path $workRoot 'module\FabricCapacityOverage'
Initialize-ReleaseStage -SourceRoot $source -StageRoot $stage -ModuleInfo $info -Confirm:$false
Write-ReleaseOutput -Name 'stage_path' -Value $stage
Write-ReleaseOutput -Name 'artifact_name' -Value "FabricCapacityOverage-signed-$($context.RunId)-$($context.RunAttempt)"
