@{
    RootModule = 'FabricCapacityOverage.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'bd717c9c-962f-4368-8a03-a6cc2bdbcc7b'
    Author = 'cbattlegear'
    Copyright = 'Copyright (c) 2026 cbattlegear. MIT License.'
    Description = 'Same-observed-workload estimates of additional Microsoft Fabric capacity overage costs from the Capacity Metrics App.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredModules = @(
        @{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.3' }
    )
    FunctionsToExport = @('Get-FabricCapacityOverageCost')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FileList = @(
        'FabricCapacityOverage.psd1'
        'FabricCapacityOverage.psm1'
        'Public\Get-FabricCapacityOverageCost.ps1'
        'Private\Utilities.ps1'
        'Private\Authentication.ps1'
        'Private\Api.ps1'
        'Private\Discovery.ps1'
        'Private\Refresh.ps1'
        'Private\Replay.ps1'
        'LICENSE'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('Fabric', 'MicrosoftFabric', 'CapacityMetrics', 'CapacityOverage', 'Azure', 'Windows', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri = 'https://github.com/cbattlegear/fabric-capacity-overage-estimator/blob/main/LICENSE'
            ProjectUri = 'https://github.com/cbattlegear/fabric-capacity-overage-estimator'
            ReleaseNotes = 'Initial module release. Az.Accounts is mandatory. Supports Windows PowerShell 5.1 and PowerShell 7 on Windows; model refresh is opt-in.'
        }
    }
}
