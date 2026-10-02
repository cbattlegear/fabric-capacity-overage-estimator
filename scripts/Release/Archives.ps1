function Get-ReleaseZipInventory {
    param([System.IO.Compression.ZipArchive] $Zip)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $total = [long] 0
    if ($Zip.Entries.Count -gt 128) { throw 'Release archive contains too many entries.' }
    foreach ($entry in $Zip.Entries) {
        $name = ConvertTo-ReleaseRelativePath $entry.FullName
        if (-not $seen.Add($name)) { throw 'Release archive has duplicate or case-colliding paths.' }
        $kind = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($kind -notin @(0, 0x8000, 0x4000) -or $entry.ExternalAttributes -band 0x400) {
            throw 'Release archives must not contain symlinks, devices or reparse points.'
        }
        $total += $entry.Length
        if ($entry.Length -gt 8388608 -or $total -gt 52428800) { throw 'Release archive exceeds the allowed size budget.' }
        if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
            if ($entry.Length -ne 0) { throw 'A release archive directory must not contain file data.' }
            continue
        }
        [pscustomobject] @{ Path = $name; Entry = $entry }
    }
}

function Read-ReleaseZipData {
    param([System.IO.Compression.ZipArchiveEntry] $Entry, [long] $MaximumBytes = 8388608)
    if ($Entry.Length -gt $MaximumBytes) { throw 'Release archive entry exceeds its size budget.' }
    $stream = $Entry.Open()
    $output = [System.IO.MemoryStream]::new()
    $buffer = [byte[]]::new(8192)
    try {
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($output.Length + $count -gt $MaximumBytes -or $output.Length + $count -gt $Entry.Length) {
                throw 'Release archive decompression exceeds its declared size or budget.'
            }
            $output.Write($buffer, 0, $count)
        }
        if ($output.Length -ne $Entry.Length) { throw 'Release archive entry data does not match its declared size.' }
        return ,$output.ToArray()
    }
    finally { $output.Dispose(); $stream.Dispose() }
}

function Read-ReleaseZipText {
    param([System.IO.Compression.ZipArchiveEntry] $Entry)
    $bytes = Read-ReleaseZipData -Entry $Entry -MaximumBytes 1048576
    return [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char] 0xFEFF)
}

function Expand-ReleaseZip {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([object[]] $Inventory, [string] $Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Release extraction requires a new, empty destination.' }
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    if ($PSCmdlet.ShouldProcess($Destination, 'Extract prevalidated release archive')) {
        $null = New-Item -ItemType Directory -Path $Destination -ErrorAction Stop
        foreach ($item in $Inventory) {
            $path = [System.IO.Path]::GetFullPath((Join-Path $Destination $item.Path.Replace('/', '\')))
            if (-not $path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Release extraction escaped its destination.' }
            $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force -ErrorAction Stop
            $bytes = Read-ReleaseZipData $item.Entry
            $outputStream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            try { $outputStream.Write($bytes, 0, $bytes.Length) }
            finally { $outputStream.Dispose() }
        }
    }
}

function ConvertFrom-ReleaseXml {
    param([string] $Content)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 1048576
    $text = [System.IO.StringReader]::new($Content)
    $reader = [System.Xml.XmlReader]::Create($text, $settings)
    try {
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    }
    finally { $reader.Dispose(); $text.Dispose() }
}
