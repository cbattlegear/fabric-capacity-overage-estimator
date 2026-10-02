function Get-ReleaseXmlValue {
    param([System.Xml.XmlNode] $Node, [string] $Name)
    $matching = @($Node.SelectNodes("*[local-name()='$Name']"))
    if ($matching.Count -ne 1) { throw "Release XML requires exactly one '$Name' field." }
    return $matching[0].InnerText
}

function Test-ReleaseNuspec {
    param([System.Xml.XmlDocument] $Document, [object] $ModuleInfo)
    $metadata = @($Document.SelectNodes("/*[local-name()='package']/*[local-name()='metadata']"))
    if ($metadata.Count -ne 1 -or (Get-ReleaseXmlValue $metadata[0] 'id') -cne $ModuleInfo.Name -or
        (Get-ReleaseXmlValue $metadata[0] 'version') -cne $ModuleInfo.Version -or
        (Get-ReleaseXmlValue $metadata[0] 'authors') -cne 'cbattlegear' -or
        (Get-ReleaseXmlValue $metadata[0] 'projectUrl') -cne $ModuleInfo.Data.PrivateData.PSData.ProjectUri -or
        (Get-ReleaseXmlValue $metadata[0] 'licenseUrl') -cne $ModuleInfo.Data.PrivateData.PSData.LicenseUri) {
        throw 'The release nuspec does not match the selected source module.'
    }
    $dependencies = @($metadata[0].SelectNodes("*[local-name()='dependencies']/*[local-name()='dependency']"))
    $expected = @($ModuleInfo.Data.RequiredModules)
    if ($expected.Count -ne 1 -or $dependencies.Count -ne 1 -or
        $dependencies[0].GetAttribute('id') -cne $expected[0].ModuleName -or
        $dependencies[0].GetAttribute('version') -cne $expected[0].ModuleVersion) {
        throw 'The release nuspec runtime dependency differs from the selected source manifest.'
    }
}

function Get-VerifiedReleasePackage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $PackagePath, [object] $ModuleInfo, [string] $ExpectedSubject, [string] $ExtractionRoot)
    if (-not $PSCmdlet.ShouldProcess($ExtractionRoot, 'Extract and authenticate every packaged release code file')) { return }
    if ((Get-Item -LiteralPath $PackagePath -ErrorAction Stop).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'The release package must be a regular file.'
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $inventory = @(Get-ReleaseZipInventory $zip)
        $moduleEntries = @()
        $nuspec = $null
        $metadataFiles = @()
        foreach ($item in $inventory) {
            if ($ModuleInfo.Files -ccontains $item.Path) { $moduleEntries += $item }
            elseif ($item.Path -ceq "$($ModuleInfo.Name).nuspec") { $nuspec = $item }
            elseif ($item.Path -cin @('_rels/.rels', '[Content_Types].xml') -or
                $item.Path -cmatch '^package/services/metadata/core-properties/[a-f0-9]{32}\.psmdcp$') {
                $metadataFiles += $item
            }
            else { throw "Unaccounted packaged release file '$($item.Path)'." }
        }
        if ($moduleEntries.Count -ne $ModuleInfo.Files.Count -or $null -eq $nuspec -or $metadataFiles.Count -ne 3) {
            throw 'The release package inventory is incomplete or unexpected.'
        }
        Expand-ReleaseZip -Inventory $moduleEntries -Destination $ExtractionRoot -Confirm:$false
    }
    finally { $zip.Dispose() }

    # Every packaged code file is authenticated before any manifest processing.
    $files = @(Test-ReleaseModuleSignature -Root $ExtractionRoot -ModuleInfo $ModuleInfo -ExpectedSubject $ExpectedSubject)
    $packaged = Get-ReleaseModuleInfo (Get-Content -LiteralPath (Join-Path $ExtractionRoot 'FabricCapacityOverage.psd1') -Raw)
    if ($packaged.Version -cne $ModuleInfo.Version -or $packaged.GUID -cne $ModuleInfo.GUID -or
        ($packaged.Files -join "`n") -cne ($ModuleInfo.Files -join "`n")) {
        throw 'The signed manifest differs from the selected source release contract.'
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $document = ConvertFrom-ReleaseXml (Read-ReleaseZipText ($zip.GetEntry("$($ModuleInfo.Name).nuspec")))
        Test-ReleaseNuspec -Document $document -ModuleInfo $ModuleInfo
    }
    finally { $zip.Dispose() }
    return [pscustomobject] @{ PackagePath = $PackagePath; PackageSHA256 = Get-ReleaseFileHash $PackagePath; Files = $files }
}

function Get-ReleaseProvenance {
    param([object] $Context, [object] $ModuleInfo, [string] $Subject, [object] $Package)
    return [pscustomobject] @{
        SchemaVersion = 1
        Repository = $Context.Repository
        Branch = 'main'
        WorkflowPath = '.github/workflows/sign-module.yml'
        SourceSHA = $Context.SourceSHA
        RunId = $Context.RunId
        RunAttempt = $Context.RunAttempt
        ModuleName = $ModuleInfo.Name
        ModuleVersion = $ModuleInfo.Version
        ModuleGUID = $ModuleInfo.GUID
        SignerSubject = Test-ReleaseSubject $Subject
        PackageFile = $ModuleInfo.PackageFile
        PackageSHA256 = $Package.PackageSHA256
        ModuleFiles = @($Package.Files | Sort-Object Path)
    }
}

function Test-ReleaseProvenance {
    param([object] $Provenance, [object] $Context, [object] $ModuleInfo, [string] $ExpectedSubject)
    $expected = @{
        SchemaVersion = 1
        Repository = $Context.Repository
        Branch = 'main'
        WorkflowPath = '.github/workflows/sign-module.yml'
        SourceSHA = $Context.SourceSHA
        RunId = $Context.RunId
        RunAttempt = $Context.RunAttempt
        ModuleName = $ModuleInfo.Name
        ModuleVersion = $ModuleInfo.Version
        ModuleGUID = $ModuleInfo.GUID
        SignerSubject = Test-ReleaseSubject $ExpectedSubject
        PackageFile = $ModuleInfo.PackageFile
    }
    $allowed = @($expected.Keys) + @('PackageSHA256', 'ModuleFiles')
    if (@($Provenance.PSObject.Properties.Name | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw 'Release provenance contains unexpected fields.'
    }
    foreach ($name in $expected.Keys) {
        if ([string] (Get-ReleaseProperty $Provenance $name) -cne [string] $expected[$name]) {
            throw "Release provenance '$name' does not match the selected signing run/source/configuration."
        }
    }
    $null = Test-ReleaseHash (Get-ReleaseProperty $Provenance 'PackageSHA256')
    $files = Get-ReleaseProperty $Provenance 'ModuleFiles'
    if ($files -isnot [array] -or $files.Count -ne $ModuleInfo.Files.Count) { throw 'Release provenance has an incomplete file inventory.' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $path = ConvertTo-ReleaseRelativePath (Get-ReleaseProperty $file 'Path')
        if ($ModuleInfo.Files -cnotcontains $path -or -not $seen.Add($path)) { throw 'Release provenance has unexpected or duplicate files.' }
        $null = Test-ReleaseHash (Get-ReleaseProperty $file 'SHA256')
    }
}

function Write-ReleaseBundle {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $Destination, [object] $Provenance, [string] $PackagePath)
    if (Test-Path -LiteralPath $Destination) { throw 'Release bundle output must be a new directory.' }
    if ($PSCmdlet.ShouldProcess($Destination, 'Create immutable signed release bundle')) {
        $null = New-Item -ItemType Directory -Path $Destination -ErrorAction Stop
        Copy-Item -LiteralPath $PackagePath -Destination (Join-Path $Destination $Provenance.PackageFile) -ErrorAction Stop
        Write-ReleaseJson -Value $Provenance -Path (Join-Path $Destination 'release-provenance.json') -Confirm:$false
        $line = "$($Provenance.PackageSHA256)  $($Provenance.PackageFile)`n"
        [System.IO.File]::WriteAllText((Join-Path $Destination 'SHA256SUMS'), $line, [System.Text.UTF8Encoding]::new($false))
    }
}

function Get-VerifiedReleaseBundle {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $BundleRoot, [object] $Context, [object] $ModuleInfo, [string] $ExpectedSubject, [string] $ExtractionRoot)
    if (-not $PSCmdlet.ShouldProcess($ExtractionRoot, 'Verify and extract the exact signed release bundle')) { return }
    $items = @(Get-ChildItem -LiteralPath $BundleRoot -Force -Recurse -ErrorAction Stop)
    $expectedFiles = @($ModuleInfo.PackageFile, 'release-provenance.json', 'SHA256SUMS')
    if ($items.Count -ne 3 -or @($items | Where-Object {
        $_.PSIsContainer -or $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint -or $expectedFiles -cnotcontains $_.Name
    }).Count -gt 0) {
        throw 'The signed artifact must contain exactly its package, provenance and SHA256SUMS.'
    }
    $provenance = Read-ReleaseJson (Join-Path $BundleRoot 'release-provenance.json')
    Test-ReleaseProvenance -Provenance $provenance -Context $Context -ModuleInfo $ModuleInfo -ExpectedSubject $ExpectedSubject
    $packagePath = Join-Path $BundleRoot $ModuleInfo.PackageFile
    $hash = Get-ReleaseFileHash $packagePath
    if ($hash -cne $provenance.PackageSHA256 -or
        (Get-Content -LiteralPath (Join-Path $BundleRoot 'SHA256SUMS') -Raw).TrimEnd("`r", "`n") -cne "$hash  $($ModuleInfo.PackageFile)") {
        throw 'The signed package hash does not match release provenance and SHA256SUMS.'
    }
    $package = Get-VerifiedReleasePackage -PackagePath $packagePath -ModuleInfo $ModuleInfo -ExpectedSubject $ExpectedSubject -ExtractionRoot $ExtractionRoot -Confirm:$false
    foreach ($file in $package.Files) {
        $expected = @($provenance.ModuleFiles | Where-Object Path -CEQ $file.Path)
        if ($expected.Count -ne 1 -or $expected[0].SHA256 -cne $file.SHA256) {
            throw "Signed packaged bytes for '$($file.Path)' differ from signing-run provenance."
        }
    }
    return [pscustomobject] @{ PackagePath = $packagePath; PackageSHA256 = $hash; Provenance = $provenance }
}

function Expand-ReleaseArtifact {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $ArchivePath, [string] $Digest, [object] $ModuleInfo, [string] $Destination)
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Extract the digest-bound immutable signing artifact')) { return }
    if ($Digest -notmatch '^sha256:([a-f0-9]{64})$' -or (Get-ReleaseFileHash $ArchivePath) -cne $Matches[1]) {
        throw 'The downloaded artifact archive differs from the immutable GitHub SHA256 digest.'
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $inventory = @(Get-ReleaseZipInventory $zip)
        $expected = @($ModuleInfo.PackageFile, 'release-provenance.json', 'SHA256SUMS')
        if ($inventory.Count -ne 3 -or @($inventory | Where-Object { $expected -cnotcontains $_.Path }).Count -gt 0) {
            throw 'The immutable signing artifact has unexpected files or directories.'
        }
        Expand-ReleaseZip -Inventory $inventory -Destination $Destination -Confirm:$false
    }
    finally { $zip.Dispose() }
}
