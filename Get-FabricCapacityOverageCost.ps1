#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility launcher for the bundled FabricCapacityOverage module.
.DESCRIPTION
This is no longer a standalone script. Keep the FabricCapacityOverage folder
beside this file and install its mandatory Az.Accounts dependency. The launcher
imports the local manifest and forwards parameters, including WhatIf/Confirm,
to the module's single public command. It contains no calculation logic.
.EXAMPLE
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001' -Days 7
.EXAMPLE
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001' -Refresh -WhatIf
.LINK
https://github.com/cbattlegear/fabric-capacity-overage-estimator
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('CapacityMetricsWorkspaceId')]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid] $WorkspaceId,

    [Alias('NumberOfDays')]
    [ValidateRange(1, 14)]
    [int] $Days = 14,

    [Alias('PaygPricePerCUHour')]
    [ValidateRange(0, 1000000)]
    [decimal] $PricePerCU = 0.18,

    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid] $SemanticModelId,

    [switch] $Refresh
)

Import-Module (Join-Path $PSScriptRoot 'FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
FabricCapacityOverage\Get-FabricCapacityOverageCost @PSBoundParameters
