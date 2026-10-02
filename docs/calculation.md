# Calculation details

## What the module estimates

The estimate covers **additional capacity overage charges**, not the base capacity bill, storage, taxes, or other services.

Capacity overage does not charge for every timepoint above 100% utilization. Fabric intervenes when its interactive-delay threshold exceeds 100%, paying off the current cumulative carryforward. `Get-FabricCapacityOverageCost` approximates that behavior from recorded Metrics App data.

The estimate assumes:

- The same observed workload and historical SKU sizes.
- Overage is enabled throughout the requested window.
- Enough rolling 24-hour overage headroom and quota to keep making payments.
- No additional work from requests that were historically rejected or deferred.

## Data and time window

1. List semantic models in the supplied workspace. Select the Capacity Metrics App model by name, or use `-SemanticModelId`. A single renamed model can also be selected; ambiguous choices fail explicitly.
2. Discover capacities from the model's `Capacities` table. Only current F-SKU capacities are eligible; trial, A, and P SKUs are excluded.
3. Read 30-second `CU Detail` and `Timepoint Overage Detail` data, with the `CapacitiesList` DirectQuery parameter explicitly set for each capacity.
4. Read the model's `UTC_offset`. All calculation windows and daily buckets use the app's clock, not the caller's local timezone.
5. End the requested rolling window at the newest timepoint with both usage and debt data for at least one selected capacity. Exclude that newest timepoint to avoid partially reported data.

`-Days` accepts 1 through 14 because compute retention is approximately 14 days. Data is queried in daily chunks, including a preceding 30-second warm-up row when available, to stay within REST API limits. DAX uses formatted timestamps to remove incompatible join lineage and includes `COUNTROWS(Series)` on every row. An expected/received row-count mismatch or a top-level, query or table error stops calculation; a missing rows array is not zero usage.

String model timestamps must be `yyyy-MM-ddTHH:mm:ss`. Already-deserialized `DateTime` values keep their clock fields regardless of `Kind`; `DateTimeOffset` values keep their wall time, not `UtcDateTime`. Both become `Unspecified` model time. Refresh-history timestamps are different: offsets are converted to UTC and unspecified refresh `DateTime` values are interpreted as UTC. No caller-local timezone is applied to model windows or daily buckets.

## Debt replay

The model supplies carryforward additions, burndown, cumulative debt, interactive-delay ratios, base CUs, and processed overage payments.

The module:

1. Preserves debt entering the window, using a preceding 30-second timepoint when available.
2. Replays additions and burndown rather than summing cumulative debt snapshots.
3. Uses the larger of recorded burndown and the unused billable timepoint budget. This matters when historical payments already cleared recorded debt, but idle capacity can still burn down hypothetical debt.
4. Adjusts the recorded interactive-delay ratio for the difference between simulated and recorded debt.
5. When the adjusted ratio exceeds 1.0, charges **all current simulated debt** and resets it to zero.
6. Resets old debt at creation, resume, pause, and deletion boundaries. Pause/deletion timepoints are excluded from hypothetical overage; ordinary pause charges are not treated as 3x overage.

The approximate delay adjustment is:

```text
adjustedDelayRatio =
    recordedDelayRatio
    + (simulatedDebtCUSeconds - recordedDebtCUSeconds) / (baseCU * 600)
```

The denominator is the capacity's 10-minute CU allowance. This is a **linear-debt approximation**, not Fabric's internal billing engine. Replay assumes cumulative debt and delay ratios reflect the state after recorded payments. Historical debt continuity is checked; incompatible timing or unexplained resets stop the calculation.

Only **payments made by the replay inside the requested window** enter the estimate. Those payments can include debt carried into the window; incoming debt is never assumed to be zero. A warm-up row initializes debt but its recorded payments are outside the requested totals. If that row already exceeds the threshold, incoming unpaid debt can be paid at the first eligible in-window timepoint. Future smoothed workload demand remains as recorded. Clearing current debt does not clear future demand.

For contiguous rows, the historical ledger must satisfy, within the larger of 0.01 CU-s or one part per million of recorded carry:

```text
beforeRecordedPayment = max(0, previousRecordedCarry + recordedAdd - recordedBurndown)
recordedCarry = max(0, beforeRecordedPayment - recordedPayment)
recordedPayment <= beforeRecordedPayment
```

A pause/deletion timepoint resets simulated debt and is excluded from hypothetical overage. Creation/resume resets old debt but permits new work at that same timepoint. Historical non-F timepoints and zero-base-CU timepoints do not generate hypothetical overage; exclusions are reported. The supplied price is uniform over the window, while historical base CU sizes drive the threshold allowance.

## Price

```text
overageCUHours = paidDebtCUSeconds / 3600
overagePricePerCUHour = PricePerCU * 3
estimatedCost = overageCUHours * overagePricePerCUHour
```

`-PricePerCU` is the **base PAYG CU-hour price**, not a CU-second price or an already-multiplied overage price. The default is 0.18, producing an overage price of 0.54.

All amounts use the currency of the supplied price. Calculations retain decimal precision; displayed costs round to two decimal places. Aggregate totals are rounded independently of per-capacity and daily amounts.

Recorded processed overages are also reported, repriced at the supplied rate. They are **separate from**, and are not added to, the what-if estimate. Azure Cost Management remains the source for actual billed currency amounts.

## Freshness and optional refresh

Default runs do not refresh the model.

- Warn when the last successful model refresh is **strictly greater than** 12 hours old.
- Separately warn when the newest available usage/debt data is **strictly greater than** 12 hours old. Compare the unrounded app clock; aligning a query boundary must not hide fractional seconds over the threshold.
- If refresh history returns HTTP 403 because the caller lacks model Write permission, explicitly warn and report model refresh age as `Unknown`, continuing to check metrics timestamps. Other failures terminate; malformed successful timestamps are not converted to `Unknown`.

`-Refresh` submits one standard model refresh and polls for that specific request's completion every 10 seconds, for up to two hours. Failure or timeout stops the calculation. Timeout does not cancel the refresh.

A refresh submission is not retried after ambiguous transport/server failures, because it might already have been accepted. Check the model's refresh history before resubmitting. A rejected authentication request can retry after obtaining a new token.

Refreshing requires model Write permission and `Dataset.ReadWrite.All`. It consumes refresh quota; shared workspaces allow eight refreshes per day, including scheduled refreshes. Refreshing imported dimensions does not create new usage for idle, paused, or unavailable capacities; the fact tables use DirectQuery.

`-Refresh -WhatIf` performs read-only discovery so it can identify the target, then submits nothing and returns no estimate. A declined `-Refresh -Confirm` behaves the same way. A completed unrelated refresh is never mistaken for the accepted request. Missing request IDs, duplicate matching history, unknown service states, failed/disabled/cancelled requests and timeout prevent calculation. Timeout does **not** cancel the service operation. Without `-Refresh`, `-WhatIf` does not suppress a read-only estimate.

## Output and missing data

The command returns one object containing overall estimates, freshness information, `Capacities`, `Daily`, `MissingDataCapacities` and `SkippedNonFCapacities`. It does not format the default output or emit currency strings.

```powershell
$result = Get-FabricCapacityOverageCost -WorkspaceId '<workspace-guid>'
$result.Capacities | Format-Table CapacityName, EstimatedOverageCUHours, EstimatedCost, DataStatus
$result.Daily | Export-Csv -LiteralPath '.\overage-by-day.csv' -NoTypeInformation
```

Missing data is not zero cost:

- Incomplete retention or debt-free gaps produce `Partial` status and warnings.
- Daily buckets with no observed data have null costs.
- A leading, interior or trailing gap with outstanding recorded/simulated debt stops the calculation. A reset on the far side of a gap cannot prove there were no unknown payments before the reset. Unexplained incoming debt after a gap is also rejected. Missing joined metrics and unexplained ledger resets stop calculation.
- A capacity with no observable usage/debt is listed in `MissingDataCapacities`. Overall totals become null, while `EstimatedCostForCapacitiesWithData` and per-capacity results remain available.
- No observable data for any eligible capacity is an error.

## Limitations

Enabling overage can admit work that was previously rejected or delayed. That additional demand cannot be reconstructed from completed-work history. The module also cannot reproduce exact service evaluation timing, spending-threshold behavior, quota restrictions, or workload changes.

Consequently, the result is neither an exact invoice prediction nor a guaranteed upper or lower bound. It is a planning estimate for the observed workload under the stated assumptions.

Metrics App schemas can change between versions. The module expects the current tables and fields described above and fails explicitly on incompatible schemas. It targets the commercial Power BI/Fabric cloud; sovereign clouds are not implemented. Windows PowerShell 5.1 and PowerShell 7 on Windows are supported; Linux/macOS are not tested.

## Authentication and runtime state

The manifest requires **Az.Accounts 5.5.3 or newer**, even when Azure CLI is present. This floor is the stable Gallery release checked during migration, whose manifest supports PowerShell 5.1 and Desktop/Core editions; it is import-tested on both Windows hosts. Use current vendor-supported minor/patch releases, rather than treating a minimum version as a security-update policy. The Azure PowerShell lifecycle requires the latest minor/patch for vendor support. No Az rollup, Power BI, XMLA, ADOMD or signing module is required.

Sign in before invoking the command with `Connect-AzAccount -Tenant '<tenant-id>'` or `az login --tenant '<tenant-id>' --allow-no-subscriptions`. CLI is tried first and falls back to an authenticated Az.Accounts context. Both older string and current `SecureString` token outputs are handled; secure unmanaged buffers are zeroed after extraction. Token values/native responses are not logged.

Each invocation owns its workspace and token context. Tokens are reused within that invocation, renewed strictly after 40 minutes or once after HTTP 401, and references cleared in `finally`. Parameters, tokens and caller preference variables are not stored in module-global state. Import loads definitions and Az.Accounts only; it does not log in or mutate services.

## References

- [Capacity overage overview](https://learn.microsoft.com/fabric/enterprise/capacity-overage-overview)
- [Metrics App compute page](https://learn.microsoft.com/fabric/enterprise/metrics-app-compute-page)
- [Power BI Execute Queries API](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries)
- [Refresh model API](https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group)
- [Refresh history API](https://learn.microsoft.com/rest/api/power-bi/datasets/get-refresh-history-in-group)
- [Get-AzAccessToken (current SecureString output)](https://learn.microsoft.com/powershell/module/az.accounts/get-azaccesstoken)
- [Azure PowerShell support lifecycle](https://learn.microsoft.com/powershell/azure/azureps-support-lifecycle)
- [Az.Accounts 5.5.3 package](https://www.powershellgallery.com/packages/Az.Accounts/5.5.3)
