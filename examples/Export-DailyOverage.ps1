#Requires -Version 5.1
<#
.SYNOPSIS
Export daily estimates from an installed module after signing in separately.
.DESCRIPTION
Queries are read-only. WhatIf previews the local CSV write, not model refresh.
Returns the structured result as well; missing data remains null in the CSV.
.EXAMPLE
.\Export-DailyOverage.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001' -OutputPath '.\overage.csv'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [guid] $WorkspaceId,
    [ValidateRange(1, 14)] [int] $Days = 7,
    [string] $OutputPath = '.\overage-by-day.csv'
)

Import-Module FabricCapacityOverage -ErrorAction Stop
$result = Get-FabricCapacityOverageCost -WorkspaceId $WorkspaceId -Days $Days -ErrorAction Stop
if ($PSCmdlet.ShouldProcess($OutputPath, 'Export daily overage estimate to CSV')) {
    $result.Daily | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -ErrorAction Stop -Confirm:$false
}
$result
