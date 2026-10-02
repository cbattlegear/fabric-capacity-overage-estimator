function Get-ReleaseTestContext {
    return [pscustomobject] @{
        Repository = 'cbattlegear/fabric-capacity-overage-estimator'
        RepositoryId = '101'
        SourceSHA = ('a' * 40)
        RunId = '202'
        RunAttempt = '3'
        WorkflowPath = '.github/workflows/sign-module.yml'
        Branch = 'main'
        ArtifactName = 'FabricCapacityOverage-signed-202-3'
    }
}

function Get-ReleaseTestEnvironment {
    param([string] $Workflow = 'sign-module.yml')
    return @{
        GITHUB_ACTIONS = 'true'
        GITHUB_EVENT_NAME = 'workflow_dispatch'
        GITHUB_REPOSITORY = 'cbattlegear/fabric-capacity-overage-estimator'
        GITHUB_REF = 'refs/heads/main'
        DEFAULT_BRANCH = 'main'
        GITHUB_WORKFLOW_REF = "cbattlegear/fabric-capacity-overage-estimator/.github/workflows/$Workflow@refs/heads/main"
        GITHUB_SHA = ('a' * 40)
        GITHUB_RUN_ID = '202'
        GITHUB_RUN_ATTEMPT = '3'
    }
}

function Get-ReleaseTestSigningEnvironment {
    return @{
        AZURE_CLIENT_ID = '11111111-1111-1111-1111-111111111111'
        AZURE_TENANT_ID = '22222222-2222-2222-2222-222222222222'
        AZURE_SUBSCRIPTION_ID = '33333333-3333-3333-3333-333333333333'
        ARTIFACT_SIGNING_RESOURCE_GROUP = 'fixture-group'
        ARTIFACT_SIGNING_ENDPOINT = 'https://eus.codesigning.azure.net/'
        ARTIFACT_SIGNING_ACCOUNT_NAME = 'fixture-account'
        ARTIFACT_SIGNING_CERTIFICATE_PROFILE = 'fixture-profile'
        ARTIFACT_SIGNING_CERTIFICATE_SUBJECT = 'CN=Offline Fixture Publisher'
    }
}

function Get-ReleaseTestRun {
    return [pscustomobject] @{
        id = 202
        workflow_id = 303
        path = '.github/workflows/sign-module.yml'
        event = 'workflow_dispatch'
        status = 'completed'
        conclusion = 'success'
        head_branch = 'main'
        head_sha = ('a' * 40)
        run_attempt = 3
        repository = [pscustomobject] @{ id = 101; full_name = 'cbattlegear/fabric-capacity-overage-estimator' }
        head_repository = [pscustomobject] @{ id = 101; full_name = 'cbattlegear/fabric-capacity-overage-estimator' }
    }
}

function Get-ReleaseTestArtifact {
    return [pscustomobject] @{
        id = 404
        name = 'FabricCapacityOverage-signed-202-3'
        expired = $false
        size_in_bytes = 1000
        digest = 'sha256:' + ('b' * 64)
        workflow_run = [pscustomobject] @{
            id = 202
            repository_id = 101
            head_repository_id = 101
            head_branch = 'main'
            head_sha = ('a' * 40)
        }
    }
}

function Write-ReleaseTestZip {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $Path, [object[]] $Entries)
    if ($PSCmdlet.ShouldProcess($Path, 'Write synthetic offline release archive')) {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
        $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $Entries) {
                $member = $archive.CreateEntry($entry.Path)
                if ($entry.PSObject.Properties['Attributes']) { $member.ExternalAttributes = $entry.Attributes }
                $destination = $member.Open()
                try {
                    $bytes = if ($entry.Content -is [byte[]]) { $entry.Content } else { [System.Text.Encoding]::UTF8.GetBytes([string] $entry.Content) }
                    $destination.Write($bytes, 0, $bytes.Length)
                }
                finally { $destination.Dispose() }
            }
        }
        finally { $archive.Dispose(); $stream.Dispose() }
    }
}

function Write-ReleaseTestPackage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $Path, [string] $SourceRoot, [object] $ModuleInfo)
    if ($PSCmdlet.ShouldProcess($Path, 'Write deterministic unsigned package fixture (signature results are mocked)')) {
        $entries = @(foreach ($file in $ModuleInfo.Files) {
            [pscustomobject] @{ Path = $file; Content = [System.IO.File]::ReadAllBytes((Join-Path $SourceRoot $file.Replace('/', '\'))) }
        })
        $version = $ModuleInfo.Version
        $license = $ModuleInfo.Data.PrivateData.PSData.LicenseUri
        $project = $ModuleInfo.Data.PrivateData.PSData.ProjectUri
        $requiredVersion = $ModuleInfo.Data.RequiredModules[0].ModuleVersion
        $xml = "<package><metadata><id>FabricCapacityOverage</id><version>$version</version><authors>cbattlegear</authors><projectUrl>$project</projectUrl><licenseUrl>$license</licenseUrl><dependencies><dependency id=""Az.Accounts"" version=""$requiredVersion"" /></dependencies></metadata></package>"
        $entries += @(
            [pscustomobject] @{ Path = 'FabricCapacityOverage.nuspec'; Content = $xml },
            [pscustomobject] @{ Path = '_rels/.rels'; Content = '<Relationships />' },
            [pscustomobject] @{ Path = '[Content_Types].xml'; Content = '<Types />' },
            [pscustomobject] @{ Path = ('package/services/metadata/core-properties/' + ('c' * 32) + '.psmdcp'); Content = '<properties />' }
        )
        Write-ReleaseTestZip -Path $Path -Entries $entries -Confirm:$false
    }
}
