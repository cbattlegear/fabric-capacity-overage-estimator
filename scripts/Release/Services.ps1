function Invoke-ReleaseGitHubRequest {
    param([string] $Path)
    if ($Path -notmatch '^repos/cbattlegear/fabric-capacity-overage-estimator(?:/|$)' -or $Path -match '[\r\n]') {
        throw 'Release GitHub API requests must stay in this repository.'
    }
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { throw 'A read-only GitHub Actions token is required for release provenance.' }
    $headers = @{
        Authorization = "Bearer $env:GH_TOKEN"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2026-03-10'
    }
    try { return Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers -Method Get -ErrorAction Stop }
    catch { throw 'Release provenance could not be read from the fixed GitHub API. No publication is authorized.' }
}

function Test-ReleaseSigningRun {
    param([object] $Run, [object] $Workflow, [object] $Repository, [string] $RunId)
    $requested = Test-ReleaseNumber $RunId
    $name = 'cbattlegear/fabric-capacity-overage-estimator'
    if ($Repository.full_name -cne $name -or $Repository.default_branch -cne 'main' -or
        $Workflow.path -cne '.github/workflows/sign-module.yml' -or
        [string] $Run.id -cne $requested -or [string] $Run.workflow_id -cne [string] $Workflow.id -or
        $Run.path -cne '.github/workflows/sign-module.yml' -or $Run.event -cne 'workflow_dispatch' -or
        $Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or $Run.head_branch -cne 'main' -or
        $Run.repository.full_name -cne $name -or $Run.head_repository.full_name -cne $name -or
        [string] $Run.repository.id -cne [string] $Repository.id -or
        [string] $Run.head_repository.id -cne [string] $Repository.id) {
        throw 'The selected source must be a completed successful manual main signing run in this repository.'
    }
    return [pscustomobject] @{
        Repository = $name
        RepositoryId = [string] $Repository.id
        SourceSHA = Test-ReleaseHash $Run.head_sha -Length 40
        RunId = $requested
        RunAttempt = Test-ReleaseNumber ([string] $Run.run_attempt) 'signing run attempt'
        WorkflowPath = '.github/workflows/sign-module.yml'
        Branch = 'main'
        ArtifactName = "FabricCapacityOverage-signed-$requested-$(Test-ReleaseNumber ([string] $Run.run_attempt) 'signing run attempt')"
    }
}

function Test-ReleaseArtifactRecord {
    param([object] $Artifact, [object] $Context)
    if ($Artifact.name -cne $Context.ArtifactName -or $Artifact.expired -ne $false -or
        [string] $Artifact.workflow_run.id -cne $Context.RunId -or
        [string] $Artifact.workflow_run.repository_id -cne $Context.RepositoryId -or
        [string] $Artifact.workflow_run.head_repository_id -cne $Context.RepositoryId -or
        $Artifact.workflow_run.head_branch -cne 'main' -or $Artifact.workflow_run.head_sha -cne $Context.SourceSHA -or
        $Artifact.digest -notmatch '^sha256:[a-f0-9]{64}$' -or
        $Artifact.size_in_bytes -le 0 -or $Artifact.size_in_bytes -gt 52428800) {
        throw 'The immutable artifact metadata does not match the selected signing run/source.'
    }
    $null = Test-ReleaseNumber ([string] $Artifact.id) 'artifact ID'
}

function Get-ReleaseSigningSource {
    param([string] $RunId)
    $id = Test-ReleaseNumber $RunId
    $base = 'repos/cbattlegear/fabric-capacity-overage-estimator'
    $repository = Invoke-ReleaseGitHubRequest -Path $base
    $workflow = Invoke-ReleaseGitHubRequest -Path "$base/actions/workflows/sign-module.yml"
    $run = Invoke-ReleaseGitHubRequest -Path "$base/actions/runs/$id"
    $context = Test-ReleaseSigningRun -Run $run -Workflow $workflow -Repository $repository -RunId $id
    $comparison = Invoke-ReleaseGitHubRequest -Path "$base/compare/$($context.SourceSHA)...main"
    if ($comparison.status -cnotin @('ahead', 'identical')) {
        throw 'The immutable signing source SHA is not an ancestor of the current protected main branch.'
    }
    $content = Invoke-ReleaseGitHubRequest -Path "$base/contents/FabricCapacityOverage/FabricCapacityOverage.psd1?ref=$($context.SourceSHA)"
    if ($content.type -cne 'file' -or $content.encoding -cne 'base64' -or $content.size -gt 1048576 -or
        $content.path -cne 'FabricCapacityOverage/FabricCapacityOverage.psd1') {
        throw 'The selected signing source must expose the fixed module data manifest.'
    }
    $manifestText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($content.content))
    $moduleInfo = Get-ReleaseModuleInfo $manifestText
    $response = Invoke-ReleaseGitHubRequest -Path "$base/actions/runs/$id/artifacts?per_page=100"
    if ($response.artifacts -isnot [array] -or $response.total_count -ne $response.artifacts.Count) {
        throw 'The signing artifact list is incomplete; no latest/partial-list fallback is allowed.'
    }
    $matching = @($response.artifacts | Where-Object name -CEQ $context.ArtifactName)
    if ($matching.Count -ne 1) { throw 'The selected successful run/attempt must have exactly one immutable signed artifact.' }
    Test-ReleaseArtifactRecord -Artifact $matching[0] -Context $context
    return [pscustomobject] @{ Context = $context; ModuleInfo = $moduleInfo; Artifact = $matching[0] }
}

function Get-ReleaseArtifactLocation {
    param([string] $ArtifactId)
    $id = Test-ReleaseNumber $ArtifactId 'artifact ID'
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { throw 'A read-only GitHub Actions token is required.' }
    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $response = $null
    try {
        $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:GH_TOKEN)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('FabricCapacityOverage-release')
        $client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2026-03-10')
        $uri = "https://api.github.com/repos/cbattlegear/fabric-capacity-overage-estimator/actions/artifacts/$id/zip"
        $response = $client.GetAsync($uri).GetAwaiter().GetResult()
        if ([int] $response.StatusCode -ne 302 -or $null -eq $response.Headers.Location -or
            $response.Headers.Location.Scheme -ne 'https' -or $response.Headers.Location.Port -ne 443 -or
            $response.Headers.Location.UserInfo -ne '') {
            throw 'The fixed GitHub artifact API did not supply an HTTPS download redirect.'
        }
        return $response.Headers.Location.AbsoluteUri
    }
    catch { throw 'The immutable signing artifact could not be downloaded. No publication is authorized.' }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Save-ReleaseArtifact {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $ArtifactId, [string] $Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Artifact download output must not already exist.' }
    if ($PSCmdlet.ShouldProcess($Destination, 'Download the exact immutable signing artifact archive')) {
        $location = Get-ReleaseArtifactLocation -ArtifactId $ArtifactId
        # The GitHub bearer token is never forwarded to the signed storage URL.
        try { Invoke-WebRequest -Uri $location -OutFile $Destination -UseBasicParsing -ErrorAction Stop | Out-Null }
        catch { throw 'The immutable artifact download failed. No URL, token or fallback artifact is logged.' }
    }
}

function Invoke-ReleaseAzureRead {
    param([string] $ResourceId)
    if ($ResourceId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.CodeSigning/codeSigningAccounts/[A-Za-z0-9_.()-]+(?:/certificateProfiles/[A-Za-z0-9_.()-]+)?$') {
        throw 'Azure release reads must address only the exact configured account or certificate profile.'
    }
    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & az rest --method get --url "https://management.azure.com${ResourceId}?api-version=2025-10-13" --output json --only-show-errors 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $preference }
    if ($exitCode -ne 0) {
        throw 'Cannot read the exact configured signing account/profile. Verify CLI OIDC and narrowly scoped read access; no subscription-wide discovery is performed.'
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
}

function Test-ReleaseSigningResource {
    param([object] $Configuration, [object] $Account, [object] $CertificateProfile)
    if (-not [string]::Equals($Account.id, $Configuration.AccountId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing account resource ID must match the exact configured account.'
    }
    if (-not [string]::Equals($CertificateProfile.id, $Configuration.ProfileId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing certificate-profile resource ID must match the exact configured profile.'
    }
    if (-not [string]::Equals($Account.type, 'Microsoft.CodeSigning/codeSigningAccounts', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing account type must be Microsoft.CodeSigning/codeSigningAccounts (ARM type casing is ignored).'
    }
    if (-not [string]::Equals($CertificateProfile.type, 'Microsoft.CodeSigning/codeSigningAccounts/certificateProfiles', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing certificate-profile type must be Microsoft.CodeSigning/codeSigningAccounts/certificateProfiles (ARM type casing is ignored).'
    }
    if ($Account.properties.provisioningState -cne 'Succeeded') {
        throw 'Signing account provisioningState must be Succeeded.'
    }
    if ($CertificateProfile.properties.provisioningState -cne 'Succeeded') {
        throw 'Signing certificate-profile provisioningState must be Succeeded.'
    }
    if ($CertificateProfile.properties.profileType -cne 'PublicTrust') {
        throw 'Signing certificate-profile profileType must be production PublicTrust, not PrivateTrust or PublicTrustTest.'
    }
    if ($CertificateProfile.properties.status -cne 'Active') {
        throw 'Signing certificate-profile status must be Active.'
    }
    if ([string]::IsNullOrWhiteSpace($CertificateProfile.properties.identityValidationId)) {
        throw 'Signing certificate-profile identityValidationId must be nonempty authoritative identity-validation linkage.'
    }
    try { $endpoint = Test-ReleaseEndpoint $Account.properties.accountUri }
    catch { throw 'Signing account accountUri must be a valid HTTPS regional codesigning.azure.net root endpoint.' }
    if ($endpoint -cne $Configuration.Endpoint) {
        throw 'Signing account accountUri must match the exact configured regional endpoint.'
    }
}

function Get-ReleaseGalleryVersionState {
    param([object] $ModuleInfo)
    if ($ModuleInfo.Name -cne 'FabricCapacityOverage' -or $ModuleInfo.Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw 'Unexpected Gallery release identity/version.'
    }
    $uri = "https://www.powershellgallery.com/api/v2/Packages(Id='FabricCapacityOverage',Version='$($ModuleInfo.Version)')"
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' } -ErrorAction Stop
    }
    catch {
        $httpResponse = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $httpResponse -and [int] $httpResponse.Value.StatusCode -eq 404) { return 'Absent' }
        throw 'Gallery version state is Unknown because the exact version lookup failed. No publication is authorized.'
    }
    if ([int] $response.StatusCode -ne 200) { throw 'Gallery version state is Unknown; unexpected lookup status.' }
    $document = ConvertFrom-ReleaseXml $response.Content
    $ids = @($document.SelectNodes("//*[local-name()='properties']/*[local-name()='Id']"))
    $versions = @($document.SelectNodes("//*[local-name()='properties']/*[local-name()='Version']"))
    if ($ids.Count -ne 1 -or $versions.Count -ne 1 -or $ids[0].InnerText -cne $ModuleInfo.Name -or
        $versions[0].InnerText -cne $ModuleInfo.Version) {
        throw 'Gallery version state is Unknown; the feed did not return the exact requested package metadata.'
    }
    return 'Exists'
}

function Publish-VerifiedRelease {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([object] $Bundle, [object] $ModuleInfo)
    $null = Get-ReleaseContext -Environment (Get-ReleaseEnvironment) -Workflow 'publish-module.yml'
    if ((Get-ReleaseFileHash $Bundle.PackagePath) -cne $Bundle.PackageSHA256) {
        throw 'The verified package changed before publication.'
    }
    if ([string]::IsNullOrWhiteSpace($env:PSGALLERY_API_KEY)) { throw 'Protected powershell-gallery secret PSGALLERY_API_KEY is required.' }
    if ((Get-ReleaseGalleryVersionState $ModuleInfo) -cne 'Absent') {
        throw "Gallery version $($ModuleInfo.Version) already exists. It will not be overwritten or republished."
    }
    $repository = Get-PSResourceRepository -Name PSGallery -ErrorAction Stop
    if ($repository.Uri.AbsoluteUri.TrimEnd('/') -cne 'https://www.powershellgallery.com/api/v2') {
        throw 'PSGallery must resolve to the official HTTPS Gallery feed before accessing the API key.'
    }
    if ($PSCmdlet.ShouldProcess("$($ModuleInfo.Name) $($ModuleInfo.Version)", 'Publish the exact verified signed nupkg to PowerShell Gallery')) {
        try {
            $null = Publish-PSResource -NupkgPath $Bundle.PackagePath -Repository PSGallery -ApiKey $env:PSGALLERY_API_KEY -ErrorAction Stop -Verbose:$false -Debug:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        }
        catch {
            throw 'Gallery publication failed or acceptance is ambiguous. No automatic retry occurred. Check the exact Gallery version before any manual retry; credentials and underlying server output are not logged.'
        }
    }
}
