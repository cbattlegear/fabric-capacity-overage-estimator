BeforeAll {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:SourceManifest = Import-PowerShellDataFile -LiteralPath $ManifestPath
    $script:ModuleRoot = Split-Path $ManifestPath -Parent
    $script:Zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    $script:EntryNames = @($script:Zip.Entries | Select-Object -ExpandProperty FullName)
    $nuspecEntry = @($script:Zip.Entries | Where-Object { $_.FullName -match '\.nuspec$' })
    if ($nuspecEntry.Count -ne 1) { throw 'The generated package must contain exactly one nuspec.' }
    $reader = [System.IO.StreamReader]::new($nuspecEntry[0].Open())
    try { $script:Nuspec = [xml] $reader.ReadToEnd() }
    finally { $reader.Dispose() }
    $script:InstallPath = Join-Path $TestDrive 'modules\FabricCapacityOverage\1.0.0'
    $null = New-Item -ItemType Directory -Path $script:InstallPath -Force
    [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $script:InstallPath)
}

AfterAll {
    if ($null -ne $script:Zip) { $script:Zip.Dispose() }
}

Describe 'Actual generated NuGet package' {
    It 'contains the expected module identity, author and metadata' {
        $metadata = $script:Nuspec.package.metadata
        $metadata.id | Should -Be 'FabricCapacityOverage'
        $metadata.version | Should -Be '1.0.0'
        $metadata.authors | Should -Be 'cbattlegear'
        $metadata.projectUrl | Should -Be $script:SourceManifest.PrivateData.PSData.ProjectUri
        $metadata.licenseUrl | Should -Be $script:SourceManifest.PrivateData.PSData.LicenseUri
        $metadata.tags | Should -Match 'MicrosoftFabric'
        $metadata.tags | Should -Match 'Windows'
        $metadata.tags | Should -Match 'PSEdition_Desktop'
        $metadata.tags | Should -Match 'PSEdition_Core'
    }

    It 'encodes Az.Accounts as the only runtime nuspec dependency with an inclusive minimum' {
        $dependencies = @($script:Nuspec.SelectNodes("//*[local-name()='dependency']"))
        $dependencies.Count | Should -Be 1
        $dependencies[0].id | Should -Be 'Az.Accounts'
        # A bare NuGet version is an inclusive minimum, not the exact [5.5.3].
        $dependencies[0].version | Should -Be '5.5.3'
    }

    It 'ships all manifest-listed public/private files, root module, manifest and MIT license' {
        foreach ($file in $script:SourceManifest.FileList) {
            $script:EntryNames | Should -Contain $file.Replace('\', '/')
        }
        $sourceLicense = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'LICENSE') -Raw
        $installedLicense = Get-Content -LiteralPath (Join-Path $script:InstallPath 'LICENSE') -Raw
        $installedLicense | Should -Be $sourceLicense
        $installedLicense | Should -Match 'MIT License'
        $installedLicense | Should -Match 'Copyright \(c\) 2026 cbattlegear'
    }

    It 'does not package tests, workflows, development/signing tools or the compatibility launcher' {
        @($script:EntryNames | Where-Object { $_ -match '^(tests|scripts|examples|docs|\.github)/' }).Count | Should -Be 0
        $script:EntryNames | Should -Not -Contain 'Get-FabricCapacityOverageCost.ps1'
        $script:EntryNames | Should -Not -Contain 'DevelopmentDependencies.psd1'
    }

    It 'retains manifest minimum dependency semantics in the disposable installation' {
        $installed = Test-ModuleManifest -Path (Join-Path $script:InstallPath 'FabricCapacityOverage.psd1') -ErrorAction Stop
        $installed.RequiredModules.Count | Should -Be 1
        $installed.RequiredModules[0].Name | Should -Be 'Az.Accounts'
        $installed.RequiredModules[0].Version | Should -Be ([version] '5.5.3')
    }

    It 'imports the installed package in a fresh runspace with exactly one export and working help' {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $pipeline = [powershell]::Create()
        $pipeline.Runspace = $runspace
        try {
            $code = {
                param($InstallPath)
                Import-Module (Join-Path $InstallPath 'FabricCapacityOverage.psd1') -ErrorAction Stop
                [pscustomobject] @{
                    Exports = @(Get-Command -Module FabricCapacityOverage).Name
                    ModuleBase = (Get-Module FabricCapacityOverage).ModuleBase
                    Synopsis = (Get-Help Get-FabricCapacityOverageCost).Synopsis
                }
            }
            $null = $pipeline.AddScript($code.ToString()).AddArgument($script:InstallPath)
            $result = @($pipeline.Invoke())
            $pipeline.HadErrors | Should -BeFalse -Because ($pipeline.Streams.Error -join [Environment]::NewLine)
            @($result[0].Exports) | Should -Be @('Get-FabricCapacityOverageCost')
            $result[0].ModuleBase | Should -Be $script:InstallPath
            $result[0].Synopsis | Should -Match 'Estimates additional Fabric'
        }
        finally {
            $pipeline.Dispose()
            $runspace.Dispose()
        }
    }
}
