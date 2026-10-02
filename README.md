# FabricCapacityOverage

Estimate additional Microsoft Fabric capacity overage costs from the Capacity Metrics App. A planning estimate, not an invoice prediction.

Requires Windows PowerShell 5.1 (.NET Framework 4.7.2+) or PowerShell 7 on Windows, a configured Metrics App workspace, model Read/Build permission, and the tenant Execute Queries setting enabled.

```powershell
Install-Module FabricCapacityOverage -Scope CurrentUser
Connect-AzAccount -Tenant '<tenant-id>'
$result = Get-FabricCapacityOverageCost -WorkspaceId '<metrics-app-workspace-id>'
$result.Capacities | Format-Table CapacityName, EstimatedCost, DataStatus
```

Defaults: **14 days** and **0.18 base PAYG per CU-hour**, multiplied by **3**. Optional parameters: `-Days`, `-PricePerCU`, `-SemanticModelId`, and `-Refresh` (off by default).

Run `Get-Help Get-FabricCapacityOverageCost -Full` for options and output examples. [Calculation details](docs/calculation.md) | [MIT](LICENSE).
