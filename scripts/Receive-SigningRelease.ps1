#Requires -Version 7.4
[CmdletBinding()]
param()

& ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-DevelopmentEnvironment.ps1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release\Release.Helpers.ps1')
$context = Get-ReleaseContext -Environment (Get-ReleaseEnvironment) -Workflow 'publish-module.yml'
$subject = Test-ReleaseSubject $env:ARTIFACT_SIGNING_CERTIFICATE_SUBJECT
$runId = Test-ReleaseNumber $env:SIGNING_RUN_ID
$source = Get-ReleaseSigningSource -RunId $runId
$root = Get-ReleaseWorkRoot $context
if (Test-Path -LiteralPath $root) { throw 'Publication requires a fresh runner release directory.' }
$null = New-Item -ItemType Directory -Path $root -ErrorAction Stop
$archive = Join-Path $root 'selected-signing-artifact.zip'
Save-ReleaseArtifact -ArtifactId ([string] $source.Artifact.id) -Destination $archive -Confirm:$false
$bundleRoot = Join-Path $root 'signed-bundle'
Expand-ReleaseArtifact -ArchivePath $archive -Digest $source.Artifact.digest -ModuleInfo $source.ModuleInfo -Destination $bundleRoot -Confirm:$false
$verified = Get-VerifiedReleaseBundle -BundleRoot $bundleRoot -Context $source.Context -ModuleInfo $source.ModuleInfo -ExpectedSubject $subject -ExtractionRoot (Join-Path $root 'verified-download') -Confirm:$false
Write-ReleaseJson -Value $source -Path (Join-Path $root 'selected-source.json') -Confirm:$false
Write-ReleaseOutput -Name 'bundle_path' -Value $bundleRoot
Write-ReleaseOutput -Name 'module_version' -Value $source.ModuleInfo.Version
Write-ReleaseOutput -Name 'package_sha' -Value $verified.PackageSHA256
