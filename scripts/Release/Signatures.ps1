function Test-ReleaseFileSignature {
    param([string] $Path, [string] $ExpectedSubject)
    $subject = Test-ReleaseSubject $ExpectedSubject
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ([string] $signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $null -eq $signature.TimeStamperCertificate -or
        -not [string]::Equals($signature.SignerCertificate.Subject, $subject, [System.StringComparison]::Ordinal)) {
        throw "Release code '$([System.IO.Path]::GetFileName($Path))' needs a Valid, timestamped Authenticode signature from the configured publisher."
    }
}

function Get-ReleaseFileInventory {
    param([string] $Root, [object] $ModuleInfo)
    $base = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $actual = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)
    foreach ($item in $actual) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Release trees must not contain symbolic links or reparse points.' }
    }
    $files = @($actual | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -ne $ModuleInfo.Files.Count) { throw 'The staged/installed release file inventory differs from the source manifest.' }
    foreach ($file in $files) {
        $relative = ConvertTo-ReleaseRelativePath $file.FullName.Substring($base.Length)
        if ($ModuleInfo.Files -cnotcontains $relative -or -not $seen.Add($relative)) {
            throw "Unaccounted release file '$relative'."
        }
        [pscustomobject] @{ Path = $relative; SHA256 = Get-ReleaseFileHash $file.FullName }
    }
}

function Test-ReleaseModuleSignature {
    param([string] $Root, [object] $ModuleInfo, [string] $ExpectedSubject)
    $inventory = @(Get-ReleaseFileInventory -Root $Root -ModuleInfo $ModuleInfo)
    foreach ($entry in $inventory) {
        if ([System.IO.Path]::GetExtension($entry.Path) -in @('.ps1', '.psm1', '.psd1')) {
            Test-ReleaseFileSignature -Path (Join-Path $Root $entry.Path.Replace('/', '\')) -ExpectedSubject $ExpectedSubject
        }
    }
    return $inventory
}

function Initialize-ReleaseStage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $SourceRoot, [string] $StageRoot, [object] $ModuleInfo)
    $source = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\') + '\'
    $stage = [System.IO.Path]::GetFullPath($StageRoot).TrimEnd('\') + '\'
    if ($stage.StartsWith($source, [System.StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith($stage, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing staging and source directories must be separate.'
    }
    $sourceItem = Get-Item -LiteralPath $SourceRoot -ErrorAction Stop
    if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'The release source must not be a reparse point.' }
    $null = Get-ReleaseFileInventory -Root $SourceRoot -ModuleInfo $ModuleInfo
    foreach ($path in $ModuleInfo.Files) {
        if ([System.IO.Path]::GetExtension($path) -in @('.ps1', '.psm1', '.psd1') -and
            [string] (Get-AuthenticodeSignature -LiteralPath (Join-Path $SourceRoot $path.Replace('/', '\'))).Status -cne 'NotSigned') {
            throw 'Keep the checked-out source unsigned; sign only fresh release staging copies.'
        }
    }
    if (Test-Path -LiteralPath $StageRoot) { throw 'The release staging directory must not already exist.' }
    if ($PSCmdlet.ShouldProcess($StageRoot, 'Create fresh release staging from manifest-listed source files')) {
        $null = New-Item -ItemType Directory -Path $StageRoot -ErrorAction Stop
        foreach ($path in $ModuleInfo.Files) {
            $destination = Join-Path $StageRoot $path.Replace('/', '\')
            $parent = Split-Path $destination -Parent
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
            Copy-Item -LiteralPath (Join-Path $SourceRoot $path.Replace('/', '\')) -Destination $destination -ErrorAction Stop
        }
    }
}
