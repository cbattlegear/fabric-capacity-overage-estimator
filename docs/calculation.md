# Calculation details

## What the script estimates

The estimate covers **additional capacity overage charges**, not the base capacity bill, storage, taxes, or other services.

Capacity overage does not charge for every timepoint above 100% utilization. Fabric intervenes when its interactive-delay threshold exceeds 100%, paying off the current cumulative carryforward. The script approximates that behavior from recorded Metrics App data.

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

`-Days` accepts 1 through 14 because compute retention is approximately 14 days. Data is queried in daily chunks to stay within REST API limits. Query errors, inconsistent rows, and truncated responses are not accepted as zero usage.

## Debt replay

The model supplies carryforward additions, burndown, cumulative debt, interactive-delay ratios, base CUs, and processed overage payments.

The script:

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

The script pays only debt that has accumulated in the current window. Future smoothed workload demand remains as recorded. Clearing current debt does not clear future demand.

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

- Warn when the last successful model refresh is over 12 hours old.
- Separately warn when the newest available usage/debt data is over 12 hours old.
- If refresh history is inaccessible because the caller lacks model Write permission, report model refresh age as `Unknown` and continue checking metrics timestamps.

`-Refresh` submits one standard model refresh and polls for that specific request's completion every 10 seconds, for up to two hours. Failure or timeout stops the calculation. Timeout does not cancel the refresh.

A refresh submission is not retried after ambiguous transport/server failures, because it might already have been accepted. Check the model's refresh history before resubmitting. A rejected authentication request can retry after obtaining a new token.

Refreshing requires model Write permission and `Dataset.ReadWrite.All`. It consumes refresh quota; shared workspaces allow eight refreshes per day, including scheduled refreshes. Refreshing imported dimensions does not create new usage for idle, paused, or unavailable capacities; the fact tables use DirectQuery.

## Output and missing data

The script returns one object containing overall estimates, freshness information, `Capacities`, `Daily`, and `MissingDataCapacities`.

```powershell
$result = .\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '<workspace-id>'
$result.Capacities | Format-Table CapacityName, EstimatedOverageCUHours, EstimatedCost, DataStatus
$result.Daily | Export-Csv -LiteralPath '.\overage-by-day.csv' -NoTypeInformation
```

Missing data is not zero cost:

- Incomplete retention or debt-free gaps produce `Partial` status and warnings.
- Daily buckets with no observed data have null costs.
- A gap with outstanding debt, a missing usage/debt join, or an unexplained debt reset stops the calculation.
- A capacity with no observable usage/debt is listed in `MissingDataCapacities`. Overall totals become null, while `EstimatedCostForCapacitiesWithData` and per-capacity results remain available.
- No observable data for any eligible capacity is an error.

## Limitations

Enabling overage can admit work that was previously rejected or delayed. That additional demand cannot be reconstructed from completed-work history. The script also cannot reproduce exact service evaluation timing, spending-threshold behavior, quota restrictions, or workload changes.

Consequently, the result is neither an exact invoice prediction nor a guaranteed upper or lower bound. It is a planning estimate for the observed workload under the stated assumptions.

Metrics App schemas can change between versions. The script expects the current tables and fields described above and fails explicitly on incompatible schemas.

## References

- [Capacity overage overview](https://learn.microsoft.com/fabric/enterprise/capacity-overage-overview)
- [Metrics App compute page](https://learn.microsoft.com/fabric/enterprise/metrics-app-compute-page)
- [Power BI Execute Queries API](https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries)
- [Refresh model API](https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group)
- [Refresh history API](https://learn.microsoft.com/rest/api/power-bi/datasets/get-refresh-history-in-group)
