#Requires -Version 5.1
<#
.SYNOPSIS
Retrieve structured estimates from an installed FabricCapacityOverage module.
.EXAMPLE
.\Get-OverageSummary.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [guid] $WorkspaceId,
    [ValidateRange(1, 14)] [int] $Days = 7,
    [ValidateRange(0, 1000000)] [decimal] $PricePerCU = 0.18
)

Import-Module FabricCapacityOverage -ErrorAction Stop
Get-FabricCapacityOverageCost -WorkspaceId $WorkspaceId -Days $Days -PricePerCU $PricePerCU
