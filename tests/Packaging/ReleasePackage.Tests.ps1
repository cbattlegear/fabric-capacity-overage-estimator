BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'scripts\Release\Release.Helpers.ps1')
    . (Join-Path $script:Root 'tests\Fixtures\Release.Helpers.ps1')
    $script:Source = Split-Path $ManifestPath -Parent
    $script:Info = Get-ReleaseModuleInfo (Get-Content -LiteralPath $ManifestPath -Raw)
    $script:Stage = Join-Path $TestDrive 'staged\FabricCapacityOverage'
    $script:Publisher = 'CN=Offline Fixture Publisher'
    $script:Original = @(Get-ReleaseFileInventory -Root $script:Source -ModuleInfo $script:Info)
    Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'NotSigned' } }
    Initialize-ReleaseStage -SourceRoot $script:Source -StageRoot $script:Stage -ModuleInfo $script:Info -Confirm:$false
    foreach ($path in $script:Info.Files) {
        if ([System.IO.Path]::GetExtension($path) -in @('.ps1', '.psm1', '.psd1')) {
            # Synthetic comments test byte preservation only; no real signing occurs.
            [System.IO.File]::AppendAllText((Join-Path $script:Stage $path.Replace('/', '\')), "`n# SIG # Begin signature block`n# offline-test-fixture-not-a-real-signature`n# SIG # End signature block`n")
        }
    }
    $script:SignedBytes = @(Get-ReleaseFileInventory -Root $script:Stage -ModuleInfo $script:Info)
    $script:Package = & (Join-Path $script:Root 'scripts\Build-Package.ps1') -ModulePath $script:Stage -DestinationPath (Join-Path $TestDrive 'packages')
}

Describe 'Real offline PSResourceGet packaging of simulated signed staging' {
    BeforeEach {
        Mock Get-AuthenticodeSignature {
            [pscustomobject] @{ Status = 'Valid'; SignerCertificate = [pscustomobject] @{ Subject = 'CN=Offline Fixture Publisher' }; TimeStamperCertificate = [pscustomobject] @{} }
        }
    }

    It 'retains all exact staged code/comment/license bytes without changing unsigned source' {
        $package = Get-VerifiedReleasePackage -PackagePath $script:Package.FullName -ModuleInfo $script:Info -ExpectedSubject $script:Publisher -ExtractionRoot (Join-Path $TestDrive 'verified-simulated-signature') -Confirm:$false
        foreach ($entry in $package.Files) {
            @($script:SignedBytes | Where-Object { $_.Path -ceq $entry.Path -and $_.SHA256 -ceq $entry.SHA256 }).Count | Should -Be 1
        }
        foreach ($entry in (Get-ReleaseFileInventory -Root $script:Source -ModuleInfo $script:Info)) {
            @($script:Original | Where-Object { $_.Path -ceq $entry.Path -and $_.SHA256 -ceq $entry.SHA256 }).Count | Should -Be 1
        }
    }

    It 'round-trips package bytes, per-file hashes, provenance and immutable artifact archive digest' {
        $context = Get-ReleaseTestContext
        $package = Get-VerifiedReleasePackage -PackagePath $script:Package.FullName -ModuleInfo $script:Info -ExpectedSubject $script:Publisher -ExtractionRoot (Join-Path $TestDrive 'verified-roundtrip') -Confirm:$false
        $provenance = Get-ReleaseProvenance -Context $context -ModuleInfo $script:Info -Subject $script:Publisher -Package $package
        $bundle = Join-Path $TestDrive 'release-bundle'
        Write-ReleaseBundle -Destination $bundle -Provenance $provenance -PackagePath $script:Package.FullName -Confirm:$false
        $archive = Join-Path $TestDrive 'immutable-artifact.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($bundle, $archive)
        $downloaded = Join-Path $TestDrive 'downloaded'
        Expand-ReleaseArtifact -ArchivePath $archive -Digest ('sha256:' + (Get-ReleaseFileHash $archive)) -ModuleInfo $script:Info -Destination $downloaded -Confirm:$false
        $verified = Get-VerifiedReleaseBundle -BundleRoot $downloaded -Context $context -ModuleInfo $script:Info -ExpectedSubject $script:Publisher -ExtractionRoot (Join-Path $TestDrive 'verified-downloaded') -Confirm:$false
        $verified.PackageSHA256 | Should -Be (Get-ReleaseFileHash $script:Package.FullName)
        [System.IO.File]::ReadAllBytes($verified.PackagePath).Length | Should -Be $script:Package.Length
    }

    It 'refuses the same synthetic payload when actual signature status is NotSigned' {
        Mock Get-AuthenticodeSignature { [pscustomobject] @{ Status = 'NotSigned'; SignerCertificate = $null; TimeStamperCertificate = $null } }
        { Get-VerifiedReleasePackage -PackagePath $script:Package.FullName -ModuleInfo $script:Info -ExpectedSubject $script:Publisher -ExtractionRoot (Join-Path $TestDrive 'invalid-real-signature') -Confirm:$false } | Should -Throw '*timestamped Authenticode*'
    }
}
