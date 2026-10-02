BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Release\Release.Helpers.ps1')
    . (Join-Path $PSScriptRoot 'Fixtures\Release.Helpers.ps1')
    . (Join-Path $PSScriptRoot 'Fixtures\Helpers.ps1')
    Initialize-TestType -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
    $script:ReleaseSource = (Resolve-Path (Join-Path $PSScriptRoot '..\FabricCapacityOverage')).Path
    $script:ReleaseInfo = Get-ReleaseModuleInfo (Get-Content -LiteralPath (Join-Path $script:ReleaseSource 'FabricCapacityOverage.psd1') -Raw)
    $script:Subject = 'CN=Offline Fixture Publisher'
    $script:RealGalleryLookup = (Get-Command Get-ReleaseGalleryVersionState).ScriptBlock
}

Describe 'Successful signing run and immutable artifact provenance' {
    BeforeEach {
        $script:Run = Get-ReleaseTestRun
        $script:Repository = [pscustomobject] @{ id = 101; full_name = 'cbattlegear/fabric-capacity-overage-estimator'; default_branch = 'main' }
        $script:Workflow = [pscustomobject] @{ id = 303; path = '.github/workflows/sign-module.yml' }
    }

    It 'binds source SHA, exact workflow ID/path, repository and current run attempt' {
        $context = Test-ReleaseSigningRun -Run $script:Run -Workflow $script:Workflow -Repository $script:Repository -RunId '202'
        $context.ArtifactName | Should -Be 'FabricCapacityOverage-signed-202-3'
        $context.SourceSHA | Should -Be ('a' * 40)
    }

    It 'rejects run field <Field> mismatch <Value>' -TestCases @(
        @{ Field = 'id'; Value = 999 }, @{ Field = 'workflow_id'; Value = 999 },
        @{ Field = 'path'; Value = '.github/workflows/foreign.yml' },
        @{ Field = 'event'; Value = 'push' }, @{ Field = 'event'; Value = 'pull_request' },
        @{ Field = 'status'; Value = 'in_progress' }, @{ Field = 'conclusion'; Value = 'failure' },
        @{ Field = 'head_branch'; Value = 'feature' }
    ) {
        param($Field, $Value)
        $script:Run.$Field = $Value
        { Test-ReleaseSigningRun -Run $script:Run -Workflow $script:Workflow -Repository $script:Repository -RunId '202' } | Should -Throw '*completed successful manual main*'
    }

    It 'rejects foreign/fork repository and malformed immutable source SHA' {
        $script:Run.head_repository.full_name = 'foreign/fork'
        { Test-ReleaseSigningRun -Run $script:Run -Workflow $script:Workflow -Repository $script:Repository -RunId '202' } | Should -Throw
        $script:Run = Get-ReleaseTestRun
        $script:Run.head_sha = 'main'
        { Test-ReleaseSigningRun -Run $script:Run -Workflow $script:Workflow -Repository $script:Repository -RunId '202' } | Should -Throw '*hexadecimal release hash*'
    }

    It 'rejects artifact field <Field> mismatch' -TestCases @(
        @{ Field = 'name'; Value = 'latest-successful' },
        @{ Field = 'expired'; Value = $true },
        @{ Field = 'digest'; Value = 'missing' },
        @{ Field = 'size_in_bytes'; Value = 0 }
    ) {
        param($Field, $Value)
        $artifact = Get-ReleaseTestArtifact
        $artifact.$Field = $Value
        { Test-ReleaseArtifactRecord -Artifact $artifact -Context (Get-ReleaseTestContext) } | Should -Throw '*immutable artifact metadata*'
    }

    It 'rejects artifact run, repository and source-SHA mismatches' -TestCases @(
        @{ Field = 'id'; Value = 999 },
        @{ Field = 'repository_id'; Value = 999 },
        @{ Field = 'head_repository_id'; Value = 999 },
        @{ Field = 'head_branch'; Value = 'feature' },
        @{ Field = 'head_sha'; Value = ('d' * 40) }
    ) {
        param($Field, $Value)
        $artifact = Get-ReleaseTestArtifact
        $artifact.workflow_run.$Field = $Value
        { Test-ReleaseArtifactRecord -Artifact $artifact -Context (Get-ReleaseTestContext) } | Should -Throw '*immutable artifact metadata*'
    }

    It 'reads only fixed repository routes and selects the exact run attempt artifact, never latest' {
        $script:ManifestText = Get-Content -LiteralPath (Join-Path $script:ReleaseSource 'FabricCapacityOverage.psd1') -Raw
        Mock Invoke-ReleaseGitHubRequest {
            if ($Path -match '/actions/workflows/') { return $script:Workflow }
            if ($Path -match '/artifacts\?') { return [pscustomobject] @{ total_count = 1; artifacts = @((Get-ReleaseTestArtifact)) } }
            if ($Path -match '/actions/runs/') { return $script:Run }
            if ($Path -match '/compare/') { return [pscustomobject] @{ status = 'ahead' } }
            if ($Path -match '/contents/') {
                return [pscustomobject] @{
                    type = 'file'; encoding = 'base64'; size = $script:ManifestText.Length
                    path = 'FabricCapacityOverage/FabricCapacityOverage.psd1'
                    content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script:ManifestText))
                }
            }
            return $script:Repository
        }
        $source = Get-ReleaseSigningSource '202'
        $source.Artifact.id | Should -Be 404
        $source.ModuleInfo.Version | Should -Be '1.0.0'
        Should -Invoke Invoke-ReleaseGitHubRequest -Times 1 -Exactly -ParameterFilter {
            $Path -eq ('repos/cbattlegear/fabric-capacity-overage-estimator/contents/FabricCapacityOverage/FabricCapacityOverage.psd1?ref=' + ('a' * 40))
        }
    }
}

Describe 'Signed nupkg preservation and unverified-code rejection' {
    BeforeEach {
        Mock Get-AuthenticodeSignature {
            [pscustomobject] @{ Status = 'Valid'; SignerCertificate = [pscustomobject] @{ Subject = 'CN=Offline Fixture Publisher' }; TimeStamperCertificate = [pscustomobject] @{} }
        }
        Mock Import-Module { throw 'Package verification must not import executable module code.' }
        $testRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $testRoot
        $script:PackagePath = Join-Path $testRoot ($script:ReleaseInfo.PackageFile)
        Write-ReleaseTestPackage -Path $script:PackagePath -SourceRoot $script:ReleaseSource -ModuleInfo $script:ReleaseInfo -Confirm:$false
        $script:Extraction = Join-Path $testRoot 'verified-package'
        $script:Context = Get-ReleaseTestContext
    }

    It 'verifies all code and exact package metadata without importing the package' {
        $package = Get-VerifiedReleasePackage -PackagePath $script:PackagePath -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot $script:Extraction -Confirm:$false
        $package.Files.Count | Should -Be 10
        $package.PackageSHA256 | Should -Be (Get-ReleaseFileHash $script:PackagePath)
        Should -Invoke Get-AuthenticodeSignature -Times 9 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly
    }

    It 'rejects invalid signatures before any packaged manifest processing' {
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'NotSigned'; SignerCertificate = $null; TimeStamperCertificate = $null } }
        Mock ConvertFrom-ReleaseManifest { throw 'Unverified manifest was processed.' }
        { Get-VerifiedReleasePackage -PackagePath $script:PackagePath -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot $script:Extraction -Confirm:$false } | Should -Throw '*timestamped Authenticode*'
        Should -Invoke ConvertFrom-ReleaseManifest -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly
    }

    It 'matches complete bundle package and per-file hashes to the exact signing provenance' {
        $package = Get-VerifiedReleasePackage -PackagePath $script:PackagePath -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot $script:Extraction -Confirm:$false
        $provenance = Get-ReleaseProvenance -Context $script:Context -ModuleInfo $script:ReleaseInfo -Subject $script:Subject -Package $package
        $bundle = Join-Path $TestDrive 'signed-bundle'
        Write-ReleaseBundle -Destination $bundle -Provenance $provenance -PackagePath $script:PackagePath -Confirm:$false
        $verified = Get-VerifiedReleaseBundle -BundleRoot $bundle -Context $script:Context -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot (Join-Path $TestDrive 'bundle-verify') -Confirm:$false
        $verified.PackageSHA256 | Should -Be $package.PackageSHA256
    }

    It 'rejects provenance <Field> mismatch' -TestCases @(
        @{ Field = 'Repository'; Value = 'foreign/repo' },
        @{ Field = 'SourceSHA'; Value = ('d' * 40) },
        @{ Field = 'RunId'; Value = '999' },
        @{ Field = 'RunAttempt'; Value = '2' },
        @{ Field = 'Branch'; Value = 'feature' },
        @{ Field = 'WorkflowPath'; Value = '.github/workflows/foreign.yml' },
        @{ Field = 'ModuleName'; Value = 'ForeignModule' },
        @{ Field = 'ModuleVersion'; Value = '9.9.9' },
        @{ Field = 'ModuleGUID'; Value = '00000000-0000-0000-0000-000000000000' },
        @{ Field = 'SignerSubject'; Value = 'CN=Foreign Publisher' },
        @{ Field = 'PackageFile'; Value = '../unsafe.nupkg' }
    ) {
        param($Field, $Value)
        $package = [pscustomobject] @{ PackageSHA256 = Get-ReleaseFileHash $script:PackagePath; Files = @(Get-ReleaseFileInventory -Root $script:ReleaseSource -ModuleInfo $script:ReleaseInfo) }
        $provenance = Get-ReleaseProvenance -Context $script:Context -ModuleInfo $script:ReleaseInfo -Subject $script:Subject -Package $package
        $provenance.$Field = $Value
        { Test-ReleaseProvenance -Provenance $provenance -Context $script:Context -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject } | Should -Throw "*'$Field'*does not match*"
    }

    It 'rejects changed package or per-file bytes even with mocked valid signatures' {
        $package = Get-VerifiedReleasePackage -PackagePath $script:PackagePath -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot $script:Extraction -Confirm:$false
        $provenance = Get-ReleaseProvenance -Context $script:Context -ModuleInfo $script:ReleaseInfo -Subject $script:Subject -Package $package
        $bundle = Join-Path $TestDrive 'changed-bundle'
        Write-ReleaseBundle -Destination $bundle -Provenance $provenance -PackagePath $script:PackagePath -Confirm:$false
        $provenance.ModuleFiles[0].SHA256 = 'e' * 64
        Write-ReleaseJson -Value $provenance -Path (Join-Path $bundle 'release-provenance.json') -Confirm:$false
        { Get-VerifiedReleaseBundle -BundleRoot $bundle -Context $script:Context -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot (Join-Path $TestDrive 'changed-verify') -Confirm:$false } | Should -Throw '*differ from signing-run provenance*'
        [System.IO.File]::AppendAllText((Join-Path $bundle $script:ReleaseInfo.PackageFile), 'changed')
        { Get-VerifiedReleaseBundle -BundleRoot $bundle -Context $script:Context -ModuleInfo $script:ReleaseInfo -ExpectedSubject $script:Subject -ExtractionRoot (Join-Path $TestDrive 'changed-hash') -Confirm:$false } | Should -Throw '*package hash*'
    }

    It 'binds the entire download ZIP to the GitHub digest before extracting anything' {
        $archive = Join-Path $TestDrive 'artifact.zip'
        Write-ReleaseTestZip -Path $archive -Entries @([pscustomobject] @{ Path = '../escaped'; Content = 'never extracted' }) -Confirm:$false
        $destination = Join-Path $TestDrive 'unsafe-extraction'
        { Expand-ReleaseArtifact -ArchivePath $archive -Digest ('sha256:' + ('0' * 64)) -ModuleInfo $script:ReleaseInfo -Destination $destination -Confirm:$false } | Should -Throw '*immutable GitHub SHA256*'
        Test-Path -LiteralPath $destination | Should -BeFalse
        { Expand-ReleaseArtifact -ArchivePath $archive -Digest ('sha256:' + (Get-ReleaseFileHash $archive)) -ModuleInfo $script:ReleaseInfo -Destination $destination -Confirm:$false } | Should -Throw '*Unsafe*'
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
}

Describe 'Explicit Gallery duplicate/unknown state and no-secret publication' {
    BeforeEach {
        $script:SavedKey = $env:PSGALLERY_API_KEY
        $env:PSGALLERY_API_KEY = 'offline-gallery-fixture-key'
        $script:Path = Join-Path $TestDrive 'verified.nupkg'
        [System.IO.File]::WriteAllText($script:Path, 'offline fixture')
        $script:Bundle = [pscustomobject] @{ PackagePath = $script:Path; PackageSHA256 = Get-ReleaseFileHash $script:Path }
        Mock Get-ReleaseEnvironment { Get-ReleaseTestEnvironment 'publish-module.yml' }
        Mock Get-PSResourceRepository { [pscustomobject] @{ Uri = [uri] 'https://www.powershellgallery.com/api/v2' } }
        Mock Get-ReleaseGalleryVersionState { 'Absent' }
        Mock Publish-PSResource {}
    }
    AfterEach { $env:PSGALLERY_API_KEY = $script:SavedKey }

    It 'publishes only NupkgPath with the same verified bytes, never the folder Path parameter' {
        Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false
        Should -Invoke Publish-PSResource -Times 1 -Exactly -ParameterFilter {
            $NupkgPath -eq $script:Path -and $Repository -eq 'PSGallery'
        }
    }

    It 'rejects a duplicate or unknown version before touching the publication command' {
        Mock Get-ReleaseGalleryVersionState { 'Exists' }
        { Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*already exists*'
        Mock Get-ReleaseGalleryVersionState { throw 'Gallery version state is Unknown.' }
        { Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*Unknown*'
        Should -Invoke Publish-PSResource -Times 0 -Exactly
    }

    It 'fails explicitly when the protected Gallery key is missing without any publication attempt' {
        $env:PSGALLERY_API_KEY = $null
        { Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*PSGALLERY_API_KEY is required*'
        Should -Invoke Publish-PSResource -Times 0 -Exactly
        Should -Invoke Get-ReleaseGalleryVersionState -Times 0 -Exactly
    }

    It 'fails if package bytes changed or the Gallery registration points elsewhere' {
        [System.IO.File]::AppendAllText($script:Path, 'changed')
        { Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*changed before publication*'
        $script:Bundle.PackageSHA256 = Get-ReleaseFileHash $script:Path
        Mock Get-PSResourceRepository { [pscustomobject] @{ Uri = [uri] 'https://foreign.example/' } }
        { Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*official HTTPS Gallery*'
        Should -Invoke Publish-PSResource -Times 0 -Exactly
    }

    It 'does not retry or print the API key after an ambiguous upload failure' {
        Mock Publish-PSResource { throw "Unsafe upstream output: $env:PSGALLERY_API_KEY" }
        $message = try { Publish-VerifiedRelease -Bundle $script:Bundle -ModuleInfo $script:ReleaseInfo -Confirm:$false } catch { $_.Exception.Message }
        $message | Should -Match 'ambiguous.*No automatic retry'
        $message | Should -Not -Match 'offline-gallery-fixture-key|Unsafe upstream output'
        Should -Invoke Publish-PSResource -Times 1 -Exactly
    }

    It 'treats only an explicit HTTP 404 from the exact version route as absent' {
        # Invoke the real lookup body, bypassing this describe's boundary mock.
        Mock Invoke-WebRequest { throw [FabricCapacityOverage.Tests.HttpException]::new(404, $null) }
        & $script:RealGalleryLookup -ModuleInfo $script:ReleaseInfo | Should -Be 'Absent'
        Mock Invoke-WebRequest { throw [FabricCapacityOverage.Tests.HttpException]::new(503, $null) }
        { & $script:RealGalleryLookup -ModuleInfo $script:ReleaseInfo } | Should -Throw '*Unknown*'
    }
}
