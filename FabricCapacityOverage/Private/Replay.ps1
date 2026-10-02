function Get-OverageReplay {
    param(
        [object[]] $Samples,
        [datetime[]] $ResetTimes,
        [datetime] $Start,
        [datetime] $End,
        [decimal] $Rate,
        [datetime[]] $InactiveTimes = @()
    )
    $intervalTicks = [timespan]::FromSeconds(30).Ticks
    if ($Start -ge $End -or $Start.Ticks % $intervalTicks -ne 0 -or $End.Ticks % $intervalTicks -ne 0) {
        throw 'The replay window must be nonempty and aligned to 30-second timepoints.'
    }
    $ordered = @($Samples | Sort-Object Timepoint)
    if ($ordered.Count -eq 0) { throw 'No joined 30-second usage/debt data was returned. No cost can be estimated.' }
    $daily = @{}
    for ($day = $Start.Date; $day -lt $End; $day = $day.AddDays(1)) {
        $dayStart = if ($day -lt $Start) { $Start } else { $day }
        $dayEnd = if ($day.AddDays(1) -gt $End) { $End } else { $day.AddDays(1) }
        $daily[$day.ToString('yyyy-MM-dd')] = [pscustomobject] @{
            Date = $day.ToString('yyyy-MM-dd')
            EstimatedCUSeconds = [decimal] 0
            RecordedCUSeconds = [decimal] 0
            PaymentEvents = 0
            Timepoints = 0
            ExpectedTimepoints = [int] (($dayEnd - $dayStart).Ticks / $intervalTicks)
        }
    }
    $debt = [decimal] 0
    $initialDebt = [decimal] 0
    $previous = $null
    $ineligible = 0
    $count = 0
    $first = $null
    $last = $null
    foreach ($sample in $ordered) {
        if ($sample.Timepoint -lt $Start.AddSeconds(-30) -or $sample.Timepoint -ge $End -or
            $sample.Timepoint.Ticks % $intervalTicks -ne 0) {
            throw "Out-of-range or non-30-second timepoint: $($sample.Timepoint)."
        }
        if ($null -ne $previous -and $sample.Timepoint -le $previous.Timepoint) {
            throw "Duplicate or unordered timepoint $($sample.Timepoint). Capacity scoping or app schema is incompatible."
        }
        $reset = @($ResetTimes | Where-Object {
            $_ -le $sample.Timepoint -and (
                ($null -eq $previous -and $_ -eq $sample.Timepoint) -or
                ($null -ne $previous -and $_ -gt $previous.Timepoint)
            )
        }).Count -gt 0
        $inactive = $sample.Timepoint -in $InactiveTimes
        $gap = if ($null -ne $previous) { ($sample.Timepoint - $previous.Timepoint).TotalSeconds - 30 } else { 0 }
        if ($gap -gt 0) {
            # A reset at the far side of a gap cannot reconstruct payments
            # that might have occurred before that reset.
            $incoming = [math]::Max([decimal] 0, $sample.RecordedCarry + $sample.RecordedBilled - $sample.Add + $sample.Burndown)
            if ($debt -gt 0 -or $previous.RecordedCarry -gt 0 -or (-not $reset -and $incoming -gt 0)) {
                throw "Missing timepoints while debt is outstanding at $($sample.Timepoint). Cannot reliably replay burndown/payments across this gap."
            }
        }
        if ($inactive) { $debt = [decimal] 0 }
        elseif ($reset) {
            # Resume/creation clears old debt, not new work at this timepoint.
            $debt = $sample.RecordedCarry + $sample.RecordedBilled
        }
        elseif ($null -eq $previous -or $gap -gt 0) {
            $debt = $sample.RecordedCarry + $sample.RecordedBilled
            if ($count -eq 0) {
                $initialDebt = [math]::Max([decimal] 0, $debt - $sample.Add + $sample.Burndown)
            }
        }
        else {
            $beforePayment = [math]::Max([decimal] 0, $previous.RecordedCarry + $sample.Add - $sample.Burndown)
            $expectedHistorical = [math]::Max([decimal] 0, $beforePayment - $sample.RecordedBilled)
            $tolerance = [math]::Max([decimal] 0.01, $sample.RecordedCarry * [decimal] 0.000001)
            if ($sample.RecordedBilled -gt $beforePayment + $tolerance -or
                [math]::Abs($expectedHistorical - $sample.RecordedCarry) -gt $tolerance) {
                throw "Unexplained carry-forward discontinuity at $($sample.Timepoint): expected $expectedHistorical CU-s, got $($sample.RecordedCarry). Billing timing/schema differs or data is incomplete; no cost was inferred."
            }
            # Recorded burndown may be capped at zero after historical debt
            # was paid. Counterfactual debt can still use the full idle budget.
            $burndown = [math]::Max($sample.Burndown, $sample.AvailableBurndown)
            $debt = [math]::Max([decimal] 0, $debt + $sample.Add - $burndown)
        }
        if ($sample.Timepoint -lt $Start) {
            $debt = if ($inactive) { [decimal] 0 } else { $sample.RecordedCarry }
            $initialDebt = $debt
            $previous = $sample
            continue
        }
        $bucket = $daily[$sample.Timepoint.ToString('yyyy-MM-dd')]
        if ($count -eq 0) {
            $first = $sample.Timepoint
            if ($first -gt $Start -and $initialDebt -gt 0 -and -not $reset) {
                throw 'Missing leading timepoints while incoming debt is outstanding. No cost can be inferred for this window.'
            }
            if ($null -ne $previous -and $previous.DelayRatio -gt 1 -and $initialDebt -gt 0 -and
                $previous.BaseCU -gt 0 -and $previous.SKU -match '^F[1-9][0-9]*$' -and
                $sample.BaseCU -gt 0 -and $sample.SKU -match '^F[1-9][0-9]*$' -and -not $reset) {
                $bucket.EstimatedCUSeconds += $initialDebt
                $bucket.PaymentEvents++
                $burndown = [math]::Max($sample.Burndown, $sample.AvailableBurndown)
                $debt = [math]::Max([decimal] 0, $sample.Add - $burndown)
            }
        }
        $count++
        $bucket.Timepoints++
        $last = $sample.Timepoint
        $bucket.RecordedCUSeconds += $sample.RecordedBilled
        if ($inactive -or $sample.BaseCU -eq 0 -or $sample.SKU -notmatch '^F[1-9][0-9]*$') {
            if ($sample.SKU -notmatch '^F[1-9][0-9]*$') { $ineligible++ }
            $debt = [decimal] 0
        }
        else {
            $allowance = $sample.BaseCU * [decimal] 600
            $adjustedDelay = $sample.DelayRatio + (($debt - $sample.RecordedCarry) / $allowance)
            if ($adjustedDelay -gt 1 -and $debt -gt 0) {
                $bucket.EstimatedCUSeconds += $debt
                $bucket.PaymentEvents++
                $debt = [decimal] 0
            }
        }
        $previous = $sample
    }
    if ($count -eq 0) { throw 'Only pre-window data was returned. No cost can be estimated for the requested window.' }
    if ($last.AddSeconds(30) -lt $End -and ($debt -gt 0 -or $previous.RecordedCarry -gt 0)) {
        throw 'Missing trailing timepoints while debt is outstanding. No cost can be inferred for this window.'
    }
    # Counting from coverage avoids counting a leading gap twice when a
    # warm-up row exists before the requested window.
    $missing = [int] (($End - $Start).Ticks / $intervalTicks) - $count
    $estimated = [decimal] 0
    $recorded = [decimal] 0
    $payments = 0
    $detail = @(foreach ($bucket in ($daily.Values | Sort-Object Date)) {
        $estimated += $bucket.EstimatedCUSeconds
        $recorded += $bucket.RecordedCUSeconds
        $payments += $bucket.PaymentEvents
        [pscustomobject] @{
            Date = $bucket.Date
            DataStatus = if ($bucket.Timepoints -eq $bucket.ExpectedTimepoints) { 'Complete' } else { 'Partial' }
            ObservedTimepoints = $bucket.Timepoints
            ExpectedTimepoints = $bucket.ExpectedTimepoints
            EstimatedOverageCUHours = if ($bucket.Timepoints -gt 0) { [math]::Round($bucket.EstimatedCUSeconds / [decimal] 3600, 6) } else { $null }
            EstimatedCost = if ($bucket.Timepoints -gt 0) { [math]::Round($bucket.EstimatedCUSeconds / [decimal] 3600 * $Rate, 2) } else { $null }
            RecordedOverageCUHours = if ($bucket.Timepoints -gt 0) { [math]::Round($bucket.RecordedCUSeconds / [decimal] 3600, 6) } else { $null }
            RecordedCostAtSuppliedPrice = if ($bucket.Timepoints -gt 0) { [math]::Round($bucket.RecordedCUSeconds / [decimal] 3600 * $Rate, 2) } else { $null }
            PaymentEvents = $bucket.PaymentEvents
        }
    })
    return [pscustomobject] @{
        EstimatedCUSeconds = $estimated
        RecordedCUSeconds = $recorded
        InitialCarryCUSeconds = $initialDebt
        RemainingCarryCUSeconds = $debt
        PaymentEvents = $payments
        MissingTimepoints = $missing
        IneligibleTimepoints = $ineligible
        Timepoints = $count
        FirstTimepoint = $first
        LastTimepoint = $last
        DataStatus = if ($missing -gt 0) { 'Partial' } else { 'Complete' }
        Daily = $detail
    }
}
