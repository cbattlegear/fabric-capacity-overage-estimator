function Get-ReleaseProperty {
    param([object] $InputObject, [string] $Name)
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) { return ,$InputObject[$Name] }
    }
    elseif ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) { return ,$property.Value }
    }
    throw "Required release field '$Name' is missing."
}

function Test-ReleaseNumber {
    param([string] $Value, [string] $Name = 'run ID')
    $number = [uint64] 0
    if ($Value -notmatch '^[0-9]{1,20}$' -or -not [uint64]::TryParse($Value, [ref] $number) -or $number -eq 0) {
        throw "$Name must be a positive decimal integer."
    }
    return $number.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-ReleaseHash {
    param([string] $Value, [ValidateSet(40, 64)] [int] $Length = 64)
    if ($Value -notmatch "^[0-9a-fA-F]{$Length}$") { throw "Expected a $Length-character hexadecimal release hash." }
    return $Value.ToLowerInvariant()
}

function Test-ReleaseSubject {
    param([string] $Subject)
    if ([string]::IsNullOrWhiteSpace($Subject) -or $Subject.Length -gt 1024 -or $Subject -match '[\r\n]') {
        throw 'ARTIFACT_SIGNING_CERTIFICATE_SUBJECT must contain the explicit expected publisher distinguished name.'
    }
    $null = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject)
    return $Subject
}

function Get-ReleaseContext {
    param(
        [hashtable] $Environment,
        [ValidateSet('sign-module.yml', 'publish-module.yml')] [string] $Workflow
    )
    $repository = 'cbattlegear/fabric-capacity-overage-estimator'
    if ($Environment.GITHUB_ACTIONS -ne 'true' -or $Environment.GITHUB_EVENT_NAME -ne 'workflow_dispatch' -or
        $Environment.GITHUB_REPOSITORY -cne $repository -or $Environment.GITHUB_REF -cne 'refs/heads/main' -or
        $Environment.DEFAULT_BRANCH -cne 'main' -or
        $Environment.GITHUB_WORKFLOW_REF -cne "$repository/.github/workflows/$Workflow@refs/heads/main") {
        throw 'Release operations require manual dispatch of this repository workflow on the main default branch.'
    }
    return [pscustomobject] @{
        Repository = $repository
        SourceSHA = Test-ReleaseHash $Environment.GITHUB_SHA -Length 40
        RunId = Test-ReleaseNumber $Environment.GITHUB_RUN_ID
        RunAttempt = Test-ReleaseNumber $Environment.GITHUB_RUN_ATTEMPT 'run attempt'
        WorkflowPath = ".github/workflows/$Workflow"
        Branch = 'main'
    }
}

function Get-ReleaseEnvironment {
    $result = @{}
    foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_EVENT_NAME', 'GITHUB_REPOSITORY', 'GITHUB_REF', 'DEFAULT_BRANCH',
        'GITHUB_WORKFLOW_REF', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')) {
        $result[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    return $result
}

function Get-ReleaseSigningConfiguration {
    param([hashtable] $Environment)
    foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'ARTIFACT_SIGNING_RESOURCE_GROUP',
        'ARTIFACT_SIGNING_ENDPOINT', 'ARTIFACT_SIGNING_ACCOUNT_NAME', 'ARTIFACT_SIGNING_CERTIFICATE_PROFILE',
        'ARTIFACT_SIGNING_CERTIFICATE_SUBJECT')) {
        if ([string]::IsNullOrWhiteSpace($Environment[$name])) { throw "Protected artifact-signing variable '$name' is required." }
    }
    foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($Environment[$name], [ref] $id) -or $id -eq [guid]::Empty) {
            throw "Protected variable '$name' must be a nonempty GUID."
        }
    }
    foreach ($name in @('ARTIFACT_SIGNING_RESOURCE_GROUP', 'ARTIFACT_SIGNING_ACCOUNT_NAME', 'ARTIFACT_SIGNING_CERTIFICATE_PROFILE')) {
        if ($Environment[$name] -notmatch '^[A-Za-z0-9_.()-]{1,90}$' -or $Environment[$name] -in @('.', '..')) {
            throw "Protected variable '$name' is not a safe Azure resource name."
        }
    }
    $endpoint = Test-ReleaseEndpoint $Environment.ARTIFACT_SIGNING_ENDPOINT
    $accountId = "/subscriptions/$($Environment.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($Environment.ARTIFACT_SIGNING_RESOURCE_GROUP)/providers/Microsoft.CodeSigning/codeSigningAccounts/$($Environment.ARTIFACT_SIGNING_ACCOUNT_NAME)"
    return [pscustomobject] @{
        AccountId = $accountId
        ProfileId = "$accountId/certificateProfiles/$($Environment.ARTIFACT_SIGNING_CERTIFICATE_PROFILE)"
        Endpoint = $endpoint
        Subject = Test-ReleaseSubject $Environment.ARTIFACT_SIGNING_CERTIFICATE_SUBJECT
    }
}

function Get-ReleaseSigningEnvironment {
    $result = @{}
    foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'ARTIFACT_SIGNING_RESOURCE_GROUP',
        'ARTIFACT_SIGNING_ENDPOINT', 'ARTIFACT_SIGNING_ACCOUNT_NAME', 'ARTIFACT_SIGNING_CERTIFICATE_PROFILE',
        'ARTIFACT_SIGNING_CERTIFICATE_SUBJECT')) {
        $result[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    return $result
}

function Test-ReleaseEndpoint {
    param([string] $Value)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.Host -notmatch '^[a-z0-9-]+\.codesigning\.azure\.net$' -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -ne '' -or $uri.Fragment -ne '' -or $uri.UserInfo -ne '') {
        throw 'The signing endpoint must be the exact HTTPS regional codesigning.azure.net root endpoint.'
    }
    return $uri.AbsoluteUri.TrimEnd('/').ToLowerInvariant()
}

function ConvertTo-ReleaseRelativePath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 240 -or
        $Path -match '^[\\/]|[:<>"|?*\x00-\x1f]') {
        throw "Unsafe release archive/file path '$Path'."
    }
    $normalized = $Path.Replace('\', '/').TrimEnd('/')
    foreach ($segment in $normalized.Split('/')) {
        if ($segment -in @('', '.', '..') -or $segment -match '[. ]$' -or
            $segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe release archive/file path '$Path'."
        }
    }
    return $normalized
}

function ConvertFrom-ReleaseManifest {
    param([string] $Content)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref] $tokens, [ref] $errors)
    if ($errors.Count -gt 0 -or $null -ne $ast.BeginBlock -or $null -ne $ast.ProcessBlock -or
        $null -ne $ast.ParamBlock -or $null -eq $ast.EndBlock -or $ast.EndBlock.Statements.Count -ne 1) {
        throw 'Release manifests must be one literal data hashtable, not executable PowerShell.'
    }
    $statement = $ast.EndBlock.Statements[0]
    if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or
        $statement.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $statement.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw 'Release manifests must be one literal data hashtable, not executable PowerShell.'
    }
    return $statement.PipelineElements[0].Expression.SafeGetValue()
}

function Get-ReleaseModuleInfo {
    param([string] $ManifestContent)
    $data = ConvertFrom-ReleaseManifest $ManifestContent
    if ((Get-ReleaseProperty $data 'RootModule') -cne 'FabricCapacityOverage.psm1' -or
        [string] (Get-ReleaseProperty $data 'GUID') -cne 'bd717c9c-962f-4368-8a03-a6cc2bdbcc7b') {
        throw 'Unexpected release module identity.'
    }
    $version = [string] (Get-ReleaseProperty $data 'ModuleVersion')
    if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'Release ModuleVersion must be a stable three-component version.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $files = @(foreach ($file in (Get-ReleaseProperty $data 'FileList')) {
        $path = ConvertTo-ReleaseRelativePath $file
        if (-not $seen.Add($path)) { throw 'The release manifest contains duplicate file paths.' }
        $path
    })
    foreach ($required in @('FabricCapacityOverage.psd1', 'FabricCapacityOverage.psm1', 'Public/Get-FabricCapacityOverageCost.ps1', 'LICENSE')) {
        if ($files -cnotcontains $required) { throw "Release FileList must include '$required'." }
    }
    if ($files.Count -lt 4 -or @($data.FunctionsToExport).Count -ne 1 -or
        $data.FunctionsToExport[0] -cne 'Get-FabricCapacityOverageCost') {
        throw 'Unexpected release file/export contract.'
    }
    return [pscustomobject] @{
        Name = 'FabricCapacityOverage'
        Version = $version
        GUID = [string] $data.GUID
        Files = $files
        Data = $data
        PackageFile = "FabricCapacityOverage.$version.nupkg"
    }
}

function Get-ReleaseFileHash {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Write-ReleaseJson {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([object] $Value, [string] $Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Write release metadata')) {
        $json = $Value | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    }
}

function Read-ReleaseJson {
    param([string] $Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt 1048576 -or $file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'Release JSON must be a small regular file.'
    }
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Get-ReleaseWorkRoot {
    param([object] $Context)
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'Release operations need an ephemeral GitHub runner temporary directory.' }
    return Join-Path $env:RUNNER_TEMP "FabricCapacityOverage-release-$($Context.RunId)-$($Context.RunAttempt)"
}

function Get-ReleaseSourceModule {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) { throw 'The selected main checkout workspace is required.' }
    return Join-Path $env:GITHUB_WORKSPACE 'FabricCapacityOverage'
}

function Write-ReleaseOutput {
    param([string] $Name, [string] $Value)
    if ($Name -notmatch '^[a-z_]+$' -or $Value -match '[\r\n]' -or [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        throw 'Release step outputs must be safe single-line values in GitHub Actions.'
    }
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name=$Value`n", [System.Text.UTF8Encoding]::new($false))
}
