function Get-FabricCapacityOverageCost {
    <#
    .SYNOPSIS
    Estimates additional Fabric capacity overage costs from the Capacity Metrics App.

    .DESCRIPTION
    Discovers the app semantic model and all visible F-SKU capacities using only
    the app's workspace ID. Returns a structured object with totals, per-capacity
    estimates and daily detail. All costs use decimal arithmetic and the currency
    of the supplied base PAYG CU-hour price, multiplied internally by three.

    This is a same-observed-workload planning estimate, not an invoice prediction.
    Replays carry-forward additions and full idle billable burndown, preserving
    incoming debt and historical SKU sizes. Adjusts the interactive-delay ratio
    by simulated minus recorded debt divided by the ten-minute CU allowance.
    Pays all simulated current debt when the adjusted ratio exceeds 1.0, then
    resets that debt without clearing future-smoothed demand. Recorded processed
    overages are reported separately, never added to the estimate. Pause, resume,
    creation and deletion reset debt; ordinary pause charges are not 3x overage.
    Assumes unlimited overage spending/quota headroom and no additional workload
    admitted by enabling overage. The service's exact billing timing is unknowable.

    Uses the commercial Power BI Execute Queries REST API, not XMLA. Az.Accounts
    5.5.3 or newer is mandatory, even if optional Azure CLI authentication is used.
    Install only Az.Accounts, not the entire Az bundle. Authenticate separately
    with Connect-AzAccount -Tenant <tenant-id> or az login --allow-no-subscriptions.
    Azure CLI is tried first, falling back to an authenticated Az.Accounts context.
    Importing the module does not authenticate, query a model or refresh anything.
    Requires model Read/Build permission, the tenant Execute Queries setting, and
    configured Metrics App data-source credentials with capacity-admin access.

    Requires the current Metrics App Capacities, CU Detail, Timepoint Overage
    Detail and System Events schema, plus the CapacitiesList and UTC_offset
    parameters. Queries daily chunks in the app's clock and excludes the latest
    incomplete timepoint. Accepts model ISO strings and typed DateTime and
    DateTimeOffset wall-clock values without local timezone conversion.
    Incomplete retention/debt-free gaps produce Partial status. Missing joined
    metrics, debt-bearing gaps, inconsistent debt ledgers and truncated responses
    fail rather than inventing a cost. MissingDataCapacities have unknown costs:
    overall totals are null and known-data subtotals remain available.

    Refresh is off by default. Successful model refreshes or metrics strictly
    older than 12 hours warn. A refresh-history 403 explicitly reports Unknown
    freshness; unrelated API failures terminate. Refresh history needs model
    Write permission; triggering refresh also needs Dataset.ReadWrite.All.
    -Refresh submits one request and waits for that exact request, polling every
    ten seconds for up to two hours. Failure/timeout prevents calculation; timeout
    does not cancel the service operation. Ambiguous refresh submissions are not
    retried. Check history before resubmitting. Refresh consumes service quota
    and does not create missing DirectQuery usage.
    -Refresh -WhatIf or a declined -Confirm returns no costs and submits nothing.

    Supports Windows PowerShell 5.1 and PowerShell 7 on Windows. Other operating
    systems are not tested. Reported currency rounds to two decimal places;
    aggregates round independently of daily amounts.

    .PARAMETER WorkspaceId
    Required GUID of the installed Capacity Metrics App workspace, not a capacity ID.
    Alias: CapacityMetricsWorkspaceId.
    .PARAMETER Days
    Rolling days to analyze. Default 14; allowed range 1 through 14.
    Alias: NumberOfDays.
    .PARAMETER PricePerCU
    BASE PAYG CU-hour price, not CU-second or pre-multiplied overage price.
    Default decimal 0.18; overage price 0.54. Allowed range 0 through 1000000.
    Alias: PaygPricePerCUHour.
    .PARAMETER SemanticModelId
    Optional model GUID in WorkspaceId, for ambiguous or renamed models.
    .PARAMETER Refresh
    Explicitly request and await model refresh. Default false. Supports WhatIf/Confirm.

    .EXAMPLE
    Get-FabricCapacityOverageCost -WorkspaceId '00000000-0000-0000-0000-000000000001'
    Discover the Metrics App and estimate all visible F-SKU capacities for 14 days.
    .EXAMPLE
    $result = Get-FabricCapacityOverageCost -WorkspaceId '00000000-0000-0000-0000-000000000001' -Days 7 -PricePerCU 0.15
    $result.Capacities | Format-Table CapacityName, EstimatedOverageCUHours, EstimatedCost, DataStatus
    $result.Daily | Export-Csv -LiteralPath '.\overage-by-day.csv' -NoTypeInformation
    Examine structured results and export daily detail.
    .EXAMPLE
    Get-FabricCapacityOverageCost -WorkspaceId '00000000-0000-0000-0000-000000000001' -SemanticModelId '00000000-0000-0000-0000-000000000002'
    Select an explicit semantic model when discovery is ambiguous.
    .EXAMPLE
    Get-FabricCapacityOverageCost -WorkspaceId '00000000-0000-0000-0000-000000000001' -Refresh -Confirm
    Confirm refresh and calculate only after that request succeeds.
    .EXAMPLE
    Get-FabricCapacityOverageCost -WorkspaceId '00000000-0000-0000-0000-000000000001' -Refresh -WhatIf
    Preview refresh after read-only model discovery; do not submit or return costs.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
    .LINK
    https://github.com/cbattlegear/fabric-capacity-overage-estimator/blob/main/docs/calculation.md
    .LINK
    https://learn.microsoft.com/fabric/enterprise/capacity-overage-overview
    .LINK
    https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
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

    $ErrorActionPreference = 'Stop'
    $context = @{
        WorkspaceId = $WorkspaceId
        Token = $null
        TokenAcquiredAt = [datetime]::MinValue
    }
    $overageMultiplier = [decimal] 3
    try {
        $datasetResponse = Invoke-OverageApi -Context $context -Method Get -Path "groups/$WorkspaceId/datasets"
        $models = @(Get-OptionalProperty $datasetResponse 'value')
        if ($models.Count -eq 0) { throw "No semantic models are accessible in workspace $WorkspaceId." }
        $requestedId = if ($PSBoundParameters.ContainsKey('SemanticModelId')) { $SemanticModelId } else { [guid]::Empty }
        $model = Get-OverageModel -Models $models -RequestedId $requestedId -WorkspaceId $WorkspaceId
        $modelId = [guid] $model.id
        Write-Verbose "Using semantic model '$($model.name)' [$modelId]."

        $refreshResult = $null
        if ($Refresh) {
            if (-not $PSCmdlet.ShouldProcess("semantic model $modelId in workspace $WorkspaceId", 'Refresh semantic model')) {
                Write-Verbose 'Model refresh was skipped; no costs were calculated.'
                return
            }
            $refreshResult = Start-OverageModelRefresh -Context $context -ModelId $modelId -Confirm:$false
            if ($null -eq $refreshResult) {
                throw 'The approved model refresh did not complete. No costs were calculated.'
            }
        }
        $nowUtc = Get-OverageUtcNow
        $modelFreshness = Get-OverageModelFreshness -Context $context -ModelId $modelId -NowUtc $nowUtc

        $parameters = Invoke-OverageApi -Context $context -Method Get -Path "groups/$WorkspaceId/datasets/$modelId/parameters"
        $offsetParameters = @((Get-OptionalProperty $parameters 'value') | Where-Object { $_.name -eq 'UTC_offset' })
        if ($offsetParameters.Count -ne 1) {
            throw "Could not discover the model's UTC_offset. Use a current, configured Capacity Metrics App model; timezone was not guessed."
        }
        $offset = [double] 0
        $offsetText = [System.Convert]::ToString($offsetParameters[0].currentValue, [System.Globalization.CultureInfo]::InvariantCulture)
        if (-not [double]::TryParse(
            $offsetText, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref] $offset
        ) -or [double]::IsNaN($offset) -or $offset -lt -12 -or $offset -gt 14) {
            throw "Invalid Metrics App UTC_offset '$offsetText'."
        }
        $modelClockNow = [datetime]::SpecifyKind($nowUtc.AddHours($offset), [System.DateTimeKind]::Unspecified)
        $modelWindowNow = $modelClockNow.AddTicks(-($modelClockNow.Ticks % [timespan]::FromSeconds(30).Ticks))
        $capacityQuery = @'
EVALUATE
    SELECTCOLUMNS('Capacities',
        "CapacityId", 'Capacities'[Capacity Id],
        "CapacityName", 'Capacities'[Capacity name],
        "SKU", 'Capacities'[SKU])
'@
        $capacityRows = @(Invoke-OverageDax -Context $context -ModelId $modelId -Query $capacityQuery)
        $capacities = @(foreach ($row in $capacityRows) {
            $id = [guid] (Get-QueryField $row 'CapacityId')
            if ($id -eq [guid]::Empty) { throw 'The Metrics App returned an empty capacity ID.' }
            [pscustomobject] @{
                Id = $id
                Name = [string] (Get-QueryField $row 'CapacityName')
                SKU = [string] (Get-QueryField $row 'SKU')
            }
        })
        foreach ($group in ($capacities | Group-Object Id)) {
            if (@($group.Group | Select-Object Name, SKU -Unique).Count -gt 1) {
                throw "Conflicting current capacity metadata for $($group.Name). No SKU or cost was guessed."
            }
        }
        $eligible = @($capacities | Where-Object { $_.SKU -match '^F[1-9][0-9]*$' } | Sort-Object Id -Unique)
        $skipped = @($capacities | Where-Object { $_.SKU -notmatch '^F[1-9][0-9]*$' } | Sort-Object Id -Unique)
        if ($skipped.Count -gt 0) {
            Write-Warning "Excluded non-F SKUs (overage applies only to F SKUs): $(($skipped | ForEach-Object { "$($_.Name) [$($_.SKU)]" }) -join '; ')."
        }
        if ($eligible.Count -eq 0) { throw 'No eligible F-SKU capacities are visible in this Metrics App model.' }

        $latestTimes = [System.Collections.Generic.List[datetime]]::new()
        $withData = [System.Collections.Generic.List[object]]::new()
        $missingData = [System.Collections.Generic.List[object]]::new()
        foreach ($capacity in $eligible) {
            $prefix = Get-CapacityDaxPrefix $capacity.Id
            $query = @"
$prefix
EVALUATE
    ROW(
        "LastUsage", FORMAT(MAX('CU Detail'[Window start time]), "yyyy-MM-ddTHH:mm:ss"),
        "LastDebt", FORMAT(MAX('Timepoint Overage Detail'[Window start time]), "yyyy-MM-ddTHH:mm:ss"))
"@
            $bounds = @(Invoke-OverageDax -Context $context -ModelId $modelId -Query $query)
            if ($bounds.Count -ne 1) { throw "Could not determine data bounds for '$($capacity.Name)'." }
            $usageText = Get-QueryField $bounds[0] 'LastUsage'
            $debtText = Get-QueryField $bounds[0] 'LastDebt'
            if ($null -eq $usageText -or $null -eq $debtText -or
                ($usageText -is [string] -and [string]::IsNullOrWhiteSpace($usageText)) -or
                ($debtText -is [string] -and [string]::IsNullOrWhiteSpace($debtText))) {
                $missingData.Add($capacity)
                Write-Warning "No usage/carry-forward data for '$($capacity.Name)'. Its cost is unknown, not zero; overall totals will be null. Verify the app's capacity-admin credentials and refresh."
                continue
            }
            $usageTime = ConvertTo-ModelTime $usageText
            $debtTime = ConvertTo-ModelTime $debtText
            $latestTimes.Add([datetime]::new([math]::Min($usageTime.Ticks, $debtTime.Ticks)))
            $withData.Add($capacity)
        }
        if ($withData.Count -eq 0) { throw 'No eligible capacity has observable usage and carry-forward data. No cost can be calculated.' }
        $end = $latestTimes | Sort-Object -Descending | Select-Object -First 1
        if ($end -gt $modelWindowNow) { $end = $modelWindowNow }
        $start = $end.AddDays(-$Days)
        # Freshness uses the unrounded clock, not the aligned query boundary.
        $metricsAgeHours = [math]::Max([double] 0, ($modelClockNow - $end).TotalHours)
        if ($metricsAgeHours -gt 12) {
            Write-Warning "Latest available usage/debt data is $([math]::Round($metricsAgeHours, 2)) hours old (over 12 hours). The estimate ends at $($end.ToString('s')) in the app's clock, NOT now. Model refresh does not create new activity for idle or paused capacities."
        }
        $rate = $PricePerCU * $overageMultiplier
        Write-Warning 'What-if estimate: same recorded workload, linear debt/10-minute-delay approximation, unlimited rolling overage headroom. Rejected/deferred work and exact service billing timing are not reproducible from this model.'
        Write-Verbose "Window [$($start.ToString('s')), $($end.ToString('s'))) in model time (UTC offset $offset); rate $rate per CU-hour."

        $results = [System.Collections.Generic.List[object]]::new()
        $dailyResults = [System.Collections.Generic.List[object]]::new()
        $totalEstimated = [decimal] 0
        $totalRecorded = [decimal] 0
        foreach ($capacity in $withData) {
            Write-Verbose "Reading '$($capacity.Name)' [$($capacity.Id)]."
            $prefix = Get-CapacityDaxPrefix $capacity.Id
            $resetQuery = @"
$prefix
EVALUATE
    SELECTCOLUMNS(
        FILTER('System Events',
            'System Events'[Capacity Id] = "$($capacity.Id)" &&
            'System Events'[Capacity state change reason] IN { "Created", "ManuallyPaused", "ManuallyResumed", "Deleted" }),
        "ResetTime", FORMAT('System Events'[Binned capacity state transition time], "yyyy-MM-ddTHH:mm:ss"),
        "ResetReason", 'System Events'[Capacity state change reason])
ORDER BY [ResetTime]
"@
            $resetRows = @(Invoke-OverageDax -Context $context -ModelId $modelId -Query $resetQuery)
            $resetTimes = @(foreach ($row in $resetRows) { ConvertTo-ModelTime (Get-QueryField $row 'ResetTime') })
            $inactiveTimes = @(foreach ($row in $resetRows) {
                if ((Get-QueryField $row 'ResetReason') -in @('ManuallyPaused', 'Deleted')) {
                    ConvertTo-ModelTime (Get-QueryField $row 'ResetTime')
                }
            })
            $samples = [System.Collections.Generic.List[object]]::new()
            for ($cursor = $start.AddSeconds(-30); $cursor -lt $end; $cursor = $chunkEnd) {
                $chunkEnd = $cursor.Date.AddDays(1)
                if ($chunkEnd -gt $end) { $chunkEnd = $end }
                $query = Get-OverageSeriesQuery -CapacityId $capacity.Id -Start $cursor -End $chunkEnd
                $rows = @(Invoke-OverageDax -Context $context -ModelId $modelId -Query $query)
                foreach ($sample in (ConvertTo-OverageSeries -Rows $rows)) { $samples.Add($sample) }
            }
            $replay = Get-OverageReplay -Samples $samples.ToArray() -ResetTimes $resetTimes -InactiveTimes $inactiveTimes -Start $start -End $end -Rate $rate
            if ($replay.DataStatus -eq 'Partial') {
                Write-Warning "'$($capacity.Name)': $($replay.MissingTimepoints) requested 30-second timepoints are unavailable (retention, idle/paused periods, or reporting gaps). Costs cover the observed data only; this is NOT a complete $Days-day estimate."
            }
            if ($replay.IneligibleTimepoints -gt 0) {
                Write-Warning "'$($capacity.Name)': excluded $($replay.IneligibleTimepoints) historical non-F-SKU timepoints."
            }
            $totalEstimated += $replay.EstimatedCUSeconds
            $totalRecorded += $replay.RecordedCUSeconds
            $results.Add([pscustomobject] @{
                CapacityId = $capacity.Id
                CapacityName = $capacity.Name
                CurrentSKU = $capacity.SKU
                DataStatus = $replay.DataStatus
                FirstTimepoint = $replay.FirstTimepoint
                LastTimepoint = $replay.LastTimepoint
                Timepoints = $replay.Timepoints
                MissingTimepoints = $replay.MissingTimepoints
                IneligibleTimepoints = $replay.IneligibleTimepoints
                InitialCarryCUSeconds = $replay.InitialCarryCUSeconds
                RemainingCarryCUSeconds = $replay.RemainingCarryCUSeconds
                EstimatedOverageCUHours = [math]::Round($replay.EstimatedCUSeconds / [decimal] 3600, 6)
                EstimatedCost = [math]::Round($replay.EstimatedCUSeconds / [decimal] 3600 * $rate, 2)
                RecordedOverageCUHours = [math]::Round($replay.RecordedCUSeconds / [decimal] 3600, 6)
                RecordedCostAtSuppliedPrice = [math]::Round($replay.RecordedCUSeconds / [decimal] 3600 * $rate, 2)
                PaymentEvents = $replay.PaymentEvents
            })
            foreach ($day in $replay.Daily) {
                $day | Add-Member -NotePropertyName CapacityId -NotePropertyValue $capacity.Id
                $day | Add-Member -NotePropertyName CapacityName -NotePropertyValue $capacity.Name
                $dailyResults.Add($day)
            }
        }
        [pscustomobject] @{
            WorkspaceId = $WorkspaceId
            SemanticModelId = $modelId
            SemanticModelName = $model.name
            RefreshRequested = [bool] $Refresh
            RefreshRequestId = if ($null -ne $refreshResult) { $refreshResult.RequestId } else { $null }
            LastSuccessfulModelRefreshUtc = $modelFreshness.LastSuccessfulRefreshUtc
            ModelRefreshAgeHours = if ($null -ne $modelFreshness.AgeHours) { [math]::Round($modelFreshness.AgeHours, 2) } else { $null }
            ModelRefreshFreshness = $modelFreshness.Status
            LatestMetricsAgeHours = [math]::Round($metricsAgeHours, 2)
            MetricsFreshness = if ($metricsAgeHours -gt 12) { 'Stale' } else { 'Recent' }
            WindowStartModelTime = $start
            WindowEndModelTimeExclusive = $end
            ModelUTCOffsetHours = $offset
            RequestedDays = $Days
            DataStatus = if ($missingData.Count -gt 0 -or @($results | Where-Object DataStatus -eq 'Partial').Count -gt 0) { 'Partial' } else { 'Complete' }
            Scenario = 'Same observed workload; linear debt replay; no overage spending/quota limit'
            BasePricePerCUHour = $PricePerCU
            OverageMultiplier = $overageMultiplier
            OveragePricePerCUHour = $rate
            EstimatedOverageCUHours = if ($missingData.Count -eq 0) { [math]::Round($totalEstimated / [decimal] 3600, 6) } else { $null }
            EstimatedCost = if ($missingData.Count -eq 0) { [math]::Round($totalEstimated / [decimal] 3600 * $rate, 2) } else { $null }
            RecordedOverageCUHours = if ($missingData.Count -eq 0) { [math]::Round($totalRecorded / [decimal] 3600, 6) } else { $null }
            RecordedCostAtSuppliedPrice = if ($missingData.Count -eq 0) { [math]::Round($totalRecorded / [decimal] 3600 * $rate, 2) } else { $null }
            EstimatedCostForCapacitiesWithData = [math]::Round($totalEstimated / [decimal] 3600 * $rate, 2)
            RecordedCostForCapacitiesWithDataAtSuppliedPrice = [math]::Round($totalRecorded / [decimal] 3600 * $rate, 2)
            Capacities = $results.ToArray()
            Daily = $dailyResults.ToArray()
            MissingDataCapacities = $missingData.ToArray()
            SkippedNonFCapacities = $skipped
        }
    }
    finally {
        $context.Token = $null
        $context.TokenAcquiredAt = [datetime]::MinValue
    }
}
