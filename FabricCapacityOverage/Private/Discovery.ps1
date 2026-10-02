function Get-OverageModel {
    param([object[]] $Models, [guid] $RequestedId, [guid] $WorkspaceId)
    if ($RequestedId -ne [guid]::Empty) {
        $matchingModels = @($Models | Where-Object { [guid] $_.id -eq $RequestedId })
        if ($matchingModels.Count -ne 1) { throw "SemanticModelId $RequestedId is not accessible in workspace $WorkspaceId." }
        return $matchingModels[0]
    }
    $matchingModels = @($Models | Where-Object {
        $_.name -match '(?i)(Fabric|Premium).*Capacity.*Metrics|Capacity.*Metrics'
    })
    if ($matchingModels.Count -eq 1) { return $matchingModels[0] }
    if ($matchingModels.Count -eq 0 -and $Models.Count -eq 1) { return $Models[0] }
    $candidates = ($Models | ForEach-Object { "$($_.name) [$($_.id)]" }) -join '; '
    throw "Could not unambiguously identify the Capacity Metrics App model. Specify -SemanticModelId. Models: $candidates"
}

function Get-CapacityDaxPrefix {
    param([guid] $CapacityId)
    return "DEFINE`n    MPARAMETER 'CapacitiesList' = { ""$($CapacityId.ToString('D').ToUpperInvariant())"" }"
}

function Get-OverageSeriesQuery {
    param([guid] $CapacityId, [datetime] $Start, [datetime] $End)
    $prefix = Get-CapacityDaxPrefix $CapacityId
    $startDax = ConvertTo-DaxTime $Start
    $endDax = ConvertTo-DaxTime $End
    # FORMAT removes the unrelated columns' data lineage so the natural join
    # uses only one identical wall-clock timestamp key.
    return @"
$prefix
    VAR UsageRows =
        SELECTCOLUMNS(
            FILTER('CU Detail',
                'CU Detail'[Window start time] >= ($startDax) &&
                'CU Detail'[Window start time] < ($endDax)),
            "Timepoint", FORMAT('CU Detail'[Window start time], "yyyy-MM-ddTHH:mm:ss"),
            "BaseCU", 'CU Detail'[Base capacity units],
            "SKU", 'CU Detail'[SKU],
            "DelayRatio", 'CU Detail'[Interactive delay %],
            "BillableInteractiveCUSeconds", 'CU Detail'[Interactive],
            "BillableBackgroundCUSeconds", 'CU Detail'[Background],
            "RecordedBilledCUSeconds", COALESCE('CU Detail'[Processed overage], 0))
    VAR DebtRows =
        SELECTCOLUMNS(
            FILTER('Timepoint Overage Detail',
                'Timepoint Overage Detail'[Window start time] >= ($startDax) &&
                'Timepoint Overage Detail'[Window start time] < ($endDax)),
            "Timepoint", FORMAT('Timepoint Overage Detail'[Window start time], "yyyy-MM-ddTHH:mm:ss"),
            "RecordedCarryCUSeconds", 'Timepoint Overage Detail'[Cumulative carry forward],
            "AddCUSeconds", 'Timepoint Overage Detail'[Carry forward add],
            "BurndownCUSeconds", 'Timepoint Overage Detail'[Carry forward burndown])
    VAR Series = NATURALLEFTOUTERJOIN(UsageRows, DebtRows)
    VAR ExpectedRowCount = COUNTROWS(Series)
EVALUATE
    ADDCOLUMNS(Series, "ExpectedRows", ExpectedRowCount)
ORDER BY [Timepoint]
"@
}

function ConvertTo-OverageSeries {
    param([object[]] $Rows)
    foreach ($row in $Rows) {
        $expected = ConvertTo-MetricNumber (Get-QueryField $row 'ExpectedRows') 'ExpectedRows'
        if ($expected -ne $Rows.Count) {
            throw "Truncated DAX response: expected $expected rows, received $($Rows.Count). No partial query was accepted."
        }
        $baseCU = ConvertTo-MetricNumber (Get-QueryField $row 'BaseCU') 'BaseCU'
        $interactive = ConvertTo-MetricNumber (Get-QueryField $row 'BillableInteractiveCUSeconds') 'BillableInteractiveCUSeconds'
        $background = ConvertTo-MetricNumber (Get-QueryField $row 'BillableBackgroundCUSeconds') 'BillableBackgroundCUSeconds'
        [pscustomobject] @{
            Timepoint = ConvertTo-ModelTime (Get-QueryField $row 'Timepoint')
            BaseCU = $baseCU
            AvailableBurndown = [math]::Max([decimal] 0, $baseCU * [decimal] 30 - $interactive - $background)
            SKU = [string] (Get-QueryField $row 'SKU')
            DelayRatio = ConvertTo-MetricNumber (Get-QueryField $row 'DelayRatio') 'DelayRatio'
            RecordedBilled = ConvertTo-MetricNumber (Get-QueryField $row 'RecordedBilledCUSeconds') 'RecordedBilledCUSeconds'
            RecordedCarry = ConvertTo-MetricNumber (Get-QueryField $row 'RecordedCarryCUSeconds') 'RecordedCarryCUSeconds'
            Add = ConvertTo-MetricNumber (Get-QueryField $row 'AddCUSeconds') 'AddCUSeconds'
            Burndown = ConvertTo-MetricNumber (Get-QueryField $row 'BurndownCUSeconds') 'BurndownCUSeconds'
        }
    }
}
