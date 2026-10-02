BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Release\Release.Helpers.ps1')
    . (Join-Path $PSScriptRoot 'Fixtures\Release.Helpers.ps1')
    . (Join-Path $PSScriptRoot 'Fixtures\Helpers.ps1')
    Initialize-TestType -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
    $script:ReleaseSource = (Resolve-Path (Join-Path $PSScriptRoot '..\FabricCapacityOverage')).Path
    $script:ReleaseInfo = Get-ReleaseModuleInfo (Get-Content -LiteralPath (Join-Path $script:ReleaseSource 'FabricCapacityOverage.psd1') -Raw)
}

Describe 'Manual main release context and protected configuration' {
    It 'accepts only the exact manual main workflow context' {
        $context = Get-ReleaseContext -Environment (Get-ReleaseTestEnvironment) -Workflow 'sign-module.yml'
        $context.RunId | Should -Be '202'
        $context.SourceSHA | Should -Be ('a' * 40)
    }

    It 'rejects a context mismatch in <Field>' -TestCases @(
        @{ Field = 'GITHUB_ACTIONS'; Value = 'false' },
        @{ Field = 'GITHUB_EVENT_NAME'; Value = 'push' },
        @{ Field = 'GITHUB_EVENT_NAME'; Value = 'pull_request' },
        @{ Field = 'GITHUB_REF'; Value = 'refs/tags/v1.0.0' },
        @{ Field = 'GITHUB_REF'; Value = 'refs/heads/untrusted' },
        @{ Field = 'DEFAULT_BRANCH'; Value = 'other' },
        @{ Field = 'GITHUB_REPOSITORY'; Value = 'foreign/repo' },
        @{ Field = 'GITHUB_WORKFLOW_REF'; Value = 'foreign/repo/.github/workflows/sign-module.yml@refs/heads/main' }
    ) {
        param($Field, $Value)
        $environment = Get-ReleaseTestEnvironment
        $environment[$Field] = $Value
        { Get-ReleaseContext -Environment $environment -Workflow 'sign-module.yml' } | Should -Throw '*manual dispatch*main*'
    }

    It 'rejects unsafe run input <Value>' -TestCases @(
        @{ Value = '0' }, @{ Value = '-1' }, @{ Value = '1; Write-Host injected' },
        @{ Value = '1e3' }, @{ Value = ' 202' }, @{ Value = '202/attempts/1' },
        @{ Value = '18446744073709551616' }, @{ Value = '' }
    ) {
        param($Value)
        $inputValue = $Value
        { Test-ReleaseNumber $inputValue } | Should -Throw '*positive decimal integer*'
    }

    It 'normalizes safe decimal IDs without executable interpretation' {
        Test-ReleaseNumber '000202' | Should -Be '202'
    }

    It 'requires every protected signing variable' -TestCases @(
        @{ Field = 'AZURE_CLIENT_ID' }, @{ Field = 'AZURE_TENANT_ID' }, @{ Field = 'AZURE_SUBSCRIPTION_ID' },
        @{ Field = 'ARTIFACT_SIGNING_RESOURCE_GROUP' }, @{ Field = 'ARTIFACT_SIGNING_ENDPOINT' },
        @{ Field = 'ARTIFACT_SIGNING_ACCOUNT_NAME' }, @{ Field = 'ARTIFACT_SIGNING_CERTIFICATE_PROFILE' },
        @{ Field = 'ARTIFACT_SIGNING_CERTIFICATE_SUBJECT' }
    ) {
        param($Field)
        $environment = Get-ReleaseTestSigningEnvironment
        $environment.Remove($Field)
        { Get-ReleaseSigningConfiguration $environment } | Should -Throw "*'$Field' is required*"
    }

    It 'rejects malformed Azure identifiers and unsafe resource names' {
        $environment = Get-ReleaseTestSigningEnvironment
        $environment.AZURE_CLIENT_ID = 'not-a-guid'
        { Get-ReleaseSigningConfiguration $environment } | Should -Throw '*nonempty GUID*'
        $environment = Get-ReleaseTestSigningEnvironment
        $environment.ARTIFACT_SIGNING_RESOURCE_GROUP = '../other'
        { Get-ReleaseSigningConfiguration $environment } | Should -Throw '*safe Azure resource name*'
    }

    It 'rejects insecure or nonregional signing endpoint <Endpoint>' -TestCases @(
        @{ Endpoint = 'http://eus.codesigning.azure.net/' },
        @{ Endpoint = 'https://foreign.example/' },
        @{ Endpoint = 'https://eus.codesigning.azure.net/profile' },
        @{ Endpoint = 'https://eus.codesigning.azure.net/?query=value' },
        @{ Endpoint = 'https://eus.codesigning.azure.net:8443/' },
        @{ Endpoint = 'https://user@eus.codesigning.azure.net/' }
    ) {
        param($Endpoint)
        $inputEndpoint = $Endpoint
        { Test-ReleaseEndpoint $inputEndpoint } | Should -Throw '*exact HTTPS regional*'
    }

    It 'requires an explicit publisher Subject, not a rotating thumbprint' {
        { Test-ReleaseSubject '' } | Should -Throw '*explicit expected publisher*'
        { Test-ReleaseSubject "CN=Fixture`nInjected=true" } | Should -Throw '*explicit expected publisher*'
        Test-ReleaseSubject 'CN=Offline Fixture Publisher' | Should -Be 'CN=Offline Fixture Publisher'
    }

    It 'parses literal manifests without executing expressions or imports' {
        Mock Invoke-Expression { throw 'No execution is allowed.' }
        { ConvertFrom-ReleaseManifest '@{ ModuleVersion = $(throw "execute") }' } | Should -Throw
        { ConvertFrom-ReleaseManifest 'Write-Output "execute"; @{}' } | Should -Throw '*literal data hashtable*'
        Should -Invoke Invoke-Expression -Times 0 -Exactly
    }
}

Describe 'Exact Active Public Trust resource verification' {
    BeforeEach {
        $script:Configuration = Get-ReleaseSigningConfiguration (Get-ReleaseTestSigningEnvironment)
        $script:Account = [pscustomobject] @{
            id = $script:Configuration.AccountId
            type = 'Microsoft.CodeSigning/codeSigningAccounts'
            properties = [pscustomobject] @{ provisioningState = 'Succeeded'; accountUri = 'https://eus.codesigning.azure.net/' }
        }
        $script:CertificateProfile = [pscustomobject] @{
            id = $script:Configuration.ProfileId
            type = 'Microsoft.CodeSigning/codeSigningAccounts/certificateProfiles'
            properties = [pscustomobject] @{
                provisioningState = 'Succeeded'; profileType = 'PublicTrust'; status = 'Active'; identityValidationId = '123456'
            }
        }
    }

    It 'accepts authoritative opaque identity linkage and an available production profile' {
        { Test-ReleaseSigningResource -Configuration $script:Configuration -Account $script:Account -CertificateProfile $script:CertificateProfile } | Should -Not -Throw
    }

    It 'rejects profile field <Field> with <Value>' -TestCases @(
        @{ Field = 'profileType'; Value = 'PublicTrustTest' },
        @{ Field = 'profileType'; Value = 'PrivateTrust' },
        @{ Field = 'status'; Value = 'Suspended' },
        @{ Field = 'status'; Value = 'Disabled' },
        @{ Field = 'identityValidationId'; Value = '' },
        @{ Field = 'provisioningState'; Value = 'Failed' }
    ) {
        param($Field, $Value)
        $script:CertificateProfile.properties.$Field = $Value
        { Test-ReleaseSigningResource -Configuration $script:Configuration -Account $script:Account -CertificateProfile $script:CertificateProfile } | Should -Throw '*Active*production PublicTrust*'
    }

    It 'rejects a valid but wrong regional endpoint or account/profile identity' {
        $script:Account.properties.accountUri = 'https://weu.codesigning.azure.net/'
        { Test-ReleaseSigningResource -Configuration $script:Configuration -Account $script:Account -CertificateProfile $script:CertificateProfile } | Should -Throw
        $script:Account.properties.accountUri = 'https://eus.codesigning.azure.net/'
        $script:CertificateProfile.id += '-foreign'
        { Test-ReleaseSigningResource -Configuration $script:Configuration -Account $script:Account -CertificateProfile $script:CertificateProfile } | Should -Throw
    }
}

Describe 'Signature coverage and safe release staging' {
    BeforeEach {
        Mock Get-AuthenticodeSignature {
            [pscustomobject] @{ Status = 'Valid'; SignerCertificate = [pscustomobject] @{ Subject = 'CN=Offline Fixture Publisher' }; TimeStamperCertificate = [pscustomobject] @{} }
        }
    }

    It 'accepts Valid, expected publisher and timestamp without pinning the leaf' {
        { Test-ReleaseFileSignature -Path 'fixture.ps1' -ExpectedSubject 'CN=Offline Fixture Publisher' } | Should -Not -Throw
    }

    It 'rejects signature status <Status>' -TestCases @(
        @{ Status = 'NotSigned' }, @{ Status = 'HashMismatch' }, @{ Status = 'NotTrusted' }, @{ Status = 'UnknownError' }
    ) {
        param($Status)
        $script:Status = $Status
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = $script:Status; SignerCertificate = $null; TimeStamperCertificate = $null } }
        { Test-ReleaseFileSignature -Path 'fixture.ps1' -ExpectedSubject 'CN=Offline Fixture Publisher' } | Should -Throw '*Valid, timestamped*'
    }

    It 'rejects a missing timestamp or wrong subject even when the signature is Valid' {
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'Valid'; SignerCertificate = [pscustomobject] @{ Subject = 'CN=Offline Fixture Publisher' }; TimeStamperCertificate = $null } }
        { Test-ReleaseFileSignature -Path 'fixture.ps1' -ExpectedSubject 'CN=Offline Fixture Publisher' } | Should -Throw
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'Valid'; SignerCertificate = [pscustomobject] @{ Subject = 'CN=Foreign Publisher' }; TimeStamperCertificate = [pscustomobject] @{} } }
        { Test-ReleaseFileSignature -Path 'fixture.ps1' -ExpectedSubject 'CN=Offline Fixture Publisher' } | Should -Throw
    }

    It 'checks all shipped ps1/psm1/psd1 code but not the MIT license' {
        $inventory = @(Test-ReleaseModuleSignature -Root $script:ReleaseSource -ModuleInfo $script:ReleaseInfo -ExpectedSubject 'CN=Offline Fixture Publisher')
        $inventory.Count | Should -Be 10
        Should -Invoke Get-AuthenticodeSignature -Times 9 -Exactly
    }

    It 'stages only listed unsigned source files without altering the original source' {
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'NotSigned' } }
        $before = @(Get-ReleaseFileInventory -Root $script:ReleaseSource -ModuleInfo $script:ReleaseInfo | Sort-Object Path)
        $stage = Join-Path $TestDrive 'fresh-module'
        Initialize-ReleaseStage -SourceRoot $script:ReleaseSource -StageRoot $stage -ModuleInfo $script:ReleaseInfo -Confirm:$false
        @(Get-ReleaseFileInventory -Root $stage -ModuleInfo $script:ReleaseInfo).Count | Should -Be 10
        $after = @(Get-ReleaseFileInventory -Root $script:ReleaseSource -ModuleInfo $script:ReleaseInfo | Sort-Object Path)
        ($before.SHA256 -join ',') | Should -Be ($after.SHA256 -join ',')
        Test-Path -LiteralPath (Join-Path $stage 'Get-FabricCapacityOverageCost.ps1') | Should -BeFalse
    }

    It 'refuses already signed/cached source, existing staging and source overlap' {
        { Initialize-ReleaseStage -SourceRoot $script:ReleaseSource -StageRoot (Join-Path $TestDrive 'bad-signed') -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*source unsigned*'
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'NotSigned' } }
        $stage = Join-Path $TestDrive 'existing-stage'
        $null = New-Item -ItemType Directory -Path $stage
        { Initialize-ReleaseStage -SourceRoot $script:ReleaseSource -StageRoot $stage -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*must not already exist*'
        { Initialize-ReleaseStage -SourceRoot $script:ReleaseSource -StageRoot (Join-Path $script:ReleaseSource 'stage') -ModuleInfo $script:ReleaseInfo -Confirm:$false } | Should -Throw '*must be separate*'
    }
}

Describe 'Unsafe archives and nonexecuting metadata rejection' {
    It 'rejects unsafe ZIP path <Path>' -TestCases @(
        @{ Path = '../escape.ps1' }, @{ Path = 'Private/../escape.ps1' }, @{ Path = 'Private\..\escape.ps1' },
        @{ Path = '/absolute.ps1' }, @{ Path = 'C:\absolute.ps1' }, @{ Path = '\\server\share.ps1' },
        @{ Path = 'file.ps1:stream' }, @{ Path = 'Private//file.ps1' }, @{ Path = 'CON.ps1' }, @{ Path = 'file.ps1.' }
    ) {
        param($Path)
        $archivePath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.zip')
        Write-ReleaseTestZip -Path $archivePath -Entries @([pscustomobject] @{ Path = $Path; Content = 'never executed' }) -Confirm:$false
        $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try { { Get-ReleaseZipInventory $zip } | Should -Throw '*Unsafe*' }
        finally { $zip.Dispose() }
    }

    It 'rejects case-colliding entries and symlinks before extraction' {
        $path = Join-Path $TestDrive 'collision.zip'
        Write-ReleaseTestZip -Path $path -Entries @(
            [pscustomobject] @{ Path = 'Public/file.ps1'; Content = 'first' },
            [pscustomobject] @{ Path = 'public/FILE.ps1'; Content = 'second' }
        ) -Confirm:$false
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try { { Get-ReleaseZipInventory $zip } | Should -Throw '*case-colliding*' } finally { $zip.Dispose() }
        $path = Join-Path $TestDrive 'symlink.zip'
        Write-ReleaseTestZip -Path $path -Entries @([pscustomobject] @{ Path = 'link'; Content = 'target'; Attributes = (0xA000 -shl 16) }) -Confirm:$false
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try { { Get-ReleaseZipInventory $zip } | Should -Throw '*symlinks*' } finally { $zip.Dispose() }
    }

    It 'rejects external entities rather than processing injected XML' {
        { ConvertFrom-ReleaseXml '<!DOCTYPE package [<!ENTITY external SYSTEM "file:///never-read">]><package>&external;</package>' } | Should -Throw
    }

    It 'limits decompressed metadata reads rather than trusting compressed archive size' {
        $path = Join-Path $TestDrive 'metadata-budget.zip'
        Write-ReleaseTestZip -Path $path -Entries @([pscustomobject] @{ Path = 'metadata.json'; Content = ('x' * 1048577) }) -Confirm:$false
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try { { Read-ReleaseZipText $zip.GetEntry('metadata.json') } | Should -Throw '*size budget*' }
        finally { $zip.Dispose() }
    }
}
