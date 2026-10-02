#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

& ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-DevelopmentEnvironment.ps1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release\Release.Helpers.ps1')
$context = Get-ReleaseContext -Environment (Get-ReleaseEnvironment) -Workflow 'publish-module.yml'
$subject = Test-ReleaseSubject $env:ARTIFACT_SIGNING_CERTIFICATE_SUBJECT
if ([string]::IsNullOrWhiteSpace($env:PSGALLERY_API_KEY)) { throw 'Protected powershell-gallery secret PSGALLERY_API_KEY is required.' }
try {
    $source = Get-ReleaseSigningSource -RunId (Test-ReleaseNumber $env:SIGNING_RUN_ID)
    $root = Get-ReleaseWorkRoot $context
    $selected = Read-ReleaseJson (Join-Path $root 'selected-source.json')
    foreach ($name in @('RunId', 'RunAttempt', 'SourceSHA')) {
        if ([string] $selected.Context.$name -cne [string] $source.Context.$name) {
            throw 'The selected signing run/source changed before publication.'
        }
    }
    if ([string] $selected.Artifact.id -cne [string] $source.Artifact.id -or $selected.Artifact.digest -cne $source.Artifact.digest) {
        throw 'The immutable selected signing artifact changed before publication.'
    }
    $bundle = Get-VerifiedReleaseBundle -BundleRoot (Join-Path $root 'signed-bundle') -Context $source.Context -ModuleInfo $source.ModuleInfo -ExpectedSubject $subject -ExtractionRoot (Join-Path $root 'verified-for-publication') -Confirm:$false
    $dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
    Import-Module Microsoft.PowerShell.PSResourceGet -RequiredVersion $dependencies.'Microsoft.PowerShell.PSResourceGet' -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess("$($source.ModuleInfo.Name) $($source.ModuleInfo.Version)", 'Publish the unchanged verified signed package')) {
        Publish-VerifiedRelease -Bundle $bundle -ModuleInfo $source.ModuleInfo -Confirm:$false
        $summary = "Published FabricCapacityOverage $($source.ModuleInfo.Version) from signing run $($source.Context.RunId), attempt $($source.Context.RunAttempt). Package SHA256: $($bundle.PackageSHA256).`n"
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summary, [System.Text.UTF8Encoding]::new($false))
    }
}
finally { $env:PSGALLERY_API_KEY = $null }
