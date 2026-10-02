# FabricCapacityOverage

A PowerShell module estimating **additional** Fabric capacity overage costs from
the Capacity Metrics App. Same-observed-workload planning estimates, **not invoice
predictions**. Default output is an object with totals, `Capacities` and `Daily`.

**Prerequisites:** PowerShell 7 on Windows or Windows PowerShell 5.1 (.NET Framework
4.7.2+); mandatory **Az.Accounts 5.5.3+**; a configured Metrics App workspace;
model Read/Build permission and the tenant Execute Queries setting. The app's
data-source credentials need capacity-admin access. Model Write permission is
needed for refresh history and explicit refresh. No full Az bundle, Power BI
module, XMLA/ADOMD library or signing dependency.

```powershell
# Gallery installation, once a release is published (not published by this migration).
Install-Module FabricCapacityOverage -Scope CurrentUser
Import-Module FabricCapacityOverage

# Alternatively, import this checkout locally.
Install-Module Az.Accounts -MinimumVersion 5.5.3 -Scope CurrentUser
Import-Module .\FabricCapacityOverage\FabricCapacityOverage.psd1

Connect-AzAccount -Tenant '<tenant-id>'
$result = Get-FabricCapacityOverageCost -WorkspaceId '<metrics-app-workspace-guid>'
$result.Capacities | Format-Table CapacityName, EstimatedCost, DataStatus
```

Only `WorkspaceId` is required. Defaults: `Days = 14` (range 1-14),
`PricePerCU = 0.18` **BASE PAYG CU-hour price** (internally multiplied by 3),
optional `SemanticModelId`, and `Refresh = false`. Original parameter aliases
and common `WhatIf`/`Confirm` parameters are retained.

```powershell
Get-FabricCapacityOverageCost -WorkspaceId '<workspace-guid>' -Days 7 -PricePerCU 0.15
Get-FabricCapacityOverageCost -WorkspaceId '<workspace-guid>' -Refresh -Confirm
Get-FabricCapacityOverageCost -WorkspaceId '<workspace-guid>' -Refresh -WhatIf
Get-Help Get-FabricCapacityOverageCost -Full
```

Refresh is opt-in; skipped/declined refresh produces **no costs**. Freshness
strictly over 12 hours warns. Missing capacity data means **null totals**, not
zero. Optional authenticated Azure CLI is tried before Az.Accounts; Az.Accounts
must still be installed. Import itself does not authenticate or call services.

The root `Get-FabricCapacityOverageCost.ps1` remains a thin compatibility launcher:
it requires the adjacent module folder and **is no longer standalone**.
See [calculations](docs/calculation.md), [examples](examples),
[testing/packaging](docs/development.md), and [signing setup](docs/signing.md).
Linux/macOS are not tested. [MIT](LICENSE), also included in the module package.

Maintainer releases: [manual signing](docs/signing.md), then separate
[manual Gallery publication](docs/publishing.md); protected external setup is required.
