Set-StrictMode -Version Latest

foreach ($file in @('Utilities', 'Authentication', 'Api', 'Discovery', 'Refresh', 'Replay')) {
    . (Join-Path $PSScriptRoot "Private\$file.ps1")
}
. (Join-Path $PSScriptRoot 'Public\Get-FabricCapacityOverageCost.ps1')

Export-ModuleMember -Function Get-FabricCapacityOverageCost
