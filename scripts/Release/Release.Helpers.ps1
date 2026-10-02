#Requires -Version 5.1
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($file in @('Utilities', 'Signatures', 'Archives', 'Packages', 'Services')) {
    . (Join-Path $PSScriptRoot "$file.ps1")
}
