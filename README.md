# Fabric capacity overage estimator

A standalone PowerShell script that estimates additional Fabric capacity overage costs using the semantic model behind the Fabric Capacity Metrics App.

## Prerequisites

- PowerShell 5.1 or later.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) or the [Az.Accounts PowerShell module](https://learn.microsoft.com/powershell/azure/install-azps) for authentication.
- A configured Fabric Capacity Metrics App and its **workspace ID**.
- Read and Build permission on the semantic model, with the tenant's **Dataset Execute Queries REST API** setting enabled. The app's data-source credentials must have access to the monitored capacities.
- Model Write permission is needed to refresh the model or read its refresh history.

No Power BI modules, XMLA client libraries, or other dependencies are required.

## Run

Sign in with `az login --allow-no-subscriptions` or `Connect-AzAccount`, using the tenant containing the app.

From the folder containing the script:

```powershell
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '<metrics-app-workspace-id>'
```

The script discovers the semantic model and analyzes all visible F-SKU capacities. Defaults: **14 days** and a base PAYG price of **0.18 per CU-hour**, multiplied by **3** for an overage price of **0.54 per CU-hour**.

```powershell
# Override the number of days and BASE price per CU-hour.
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '<workspace-id>' -Days 7 -PricePerCU 0.15

# Explicitly refresh the model and wait for completion before calculating.
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '<workspace-id>' -Refresh
```

Refresh is **off by default**. Warnings flag model refreshes or metrics data older than 12 hours. Use `-SemanticModelId '<model-id>'` if automatic model discovery is ambiguous.

This is a **same-observed-workload what-if estimate**, not an invoice prediction. See [calculation details and limitations](docs/calculation.md), or run `Get-Help .\Get-FabricCapacityOverageCost.ps1 -Full` for more options and output examples.

## License

[MIT](LICENSE).
