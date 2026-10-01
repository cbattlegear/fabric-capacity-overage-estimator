<#
.SYNOPSIS
Estimates Fabric capacity overage costs from the Capacity Metrics App.

.DESCRIPTION
Only WorkspaceId is required. The script discovers the app's semantic model
and estimates costs for every F-SKU capacity visible in that model.
Estimates ADDITIONAL overage charges only, not the base SKU or storage bill.

Targets the commercial Fabric/Power BI cloud. Uses the Power BI Execute
Queries REST API, not XMLA. No Power BI module,
Fabric module, ADOMD library, or downloaded dependency is required. First
authenticate with either:
    az login --allow-no-subscriptions
or:
    Connect-AzAccount
Use the tenant containing the app workspace. Azure CLI is tried first; an
authenticated Az.Accounts context is used if CLI authentication is unavailable.
Requires semantic-model Read and Build permission and the tenant's
"Dataset Execute Queries REST API" setting. The app's data-source credentials
must also work and have access to the monitored capacities.

By default, the script does NOT refresh the model. It warns if the last
successful model refresh or newest available usage/debt data is over 12 hours
old. Refresh-history access requires model Write permission; if that access
is denied, refresh age is reported as Unknown and metrics timestamps are
still checked.

Use -Refresh to request a standard model refresh and wait for that exact
request to complete before querying the model. Requires model Write permission
and Dataset.ReadWrite.All. Polls every 10 seconds for up to two hours; failure
or timeout stops the calculation. A timed-out refresh is NOT cancelled.
Refresh consumes the service's refresh quota (shared workspaces allow eight
refreshes per day, including scheduled refreshes). DirectQuery facts remain
live; refreshing imported dimensions does not create missing capacity usage.

PricePerCU is the BASE pay-as-you-go price per CU-HOUR, not per CU-second and
not an already-multiplied overage price. Default: 0.18; overage: 0.54/CU-hour.
All amounts use the currency of the supplied price.

The current Metrics App schema is required: Capacities, CU Detail,
Timepoint Overage Detail, System Events, and the CapacitiesList M parameter.
Microsoft can change this app schema; incompatible schemas fail explicitly.
Compute retention is approximately 14 days. The requested rolling window ends
at the newest timepoint with both CU and debt data for at least one selected
capacity; that newest timepoint is excluded to avoid partially reported data.
Timestamps and daily buckets use the app's configured UTC_offset.
ISO timestamp strings and timestamps already deserialized by PowerShell are
accepted without converting the app's clock to the caller's local timezone.

WHAT-IF METHOD AND LIMITATIONS:
* Replay the recorded 30-second carry-forward additions and burndown.
  Use the full idle billable CU budget when recorded burndown was capped by
  historical debt that has already been paid. Exclude nonbillable usage.
* Preserve carry-forward entering the window; do not start debt at zero.
* Adjust the recorded interactive-delay ratio by the difference between
  simulated and recorded debt, divided by the 10-minute CU allowance.
  This is a linear-debt approximation, not Fabric's internal billing engine.
* When the adjusted ratio exceeds 1.0, pay ALL current carry-forward and
  reset simulated debt. Do not charge the same cumulative debt every timepoint.
* Keep future smoothed workload demand as recorded. Pause/resume/delete/create
  reset debt; ordinary pause charges are NOT 3x capacity-overage charges.
* Assume overage remains enabled with enough rolling-24-hour headroom:
  no configured spending threshold or quota restriction is simulated.
* Rejected or deferred work admitted by enabling overage is unknowable from
  completed-work history. This is a same-observed-workload estimate, NOT an
  invoice prediction or a guaranteed upper/lower bound.
* Recorded processed overages are reported separately, priced at the supplied
  rate; they are not added to the what-if estimate.
  Replay assumes cumulative debt and delay ratios represent the state after
  recorded payments; the historical debt ledger is checked for consistency.
* Incomplete retention and debt-free gaps produce explicit Partial status.
  A gap with outstanding debt, missing join data, unexplained debt resets,
  truncated responses, or query errors fails rather than inventing a cost.

Returns one object with totals, per-capacity results, and daily detail. Cost
calculations retain decimal precision; reported currency amounts round to
two decimal places. Totals are rounded independently of daily amounts.
Capacities with no observable usage/debt are listed in MissingDataCapacities.
If any are missing, overall totals are null (not zero); subtotals for capacities
with data remain available. No data for ANY eligible capacity is an error.
Nothing is enabled or configured in Azure/Fabric/Power BI. The model is only
refreshed when -Refresh is explicitly supplied.

.PARAMETER WorkspaceId
Workspace ID of the installed Capacity Metrics App, not the monitored capacity.
.PARAMETER Days
Rolling days to analyze. Default 14; allowed range 1-14 because of app retention.
.PARAMETER PricePerCU
Base PAYG price per CU-hour. Default 0.18. The script applies the 3x multiplier.
.PARAMETER SemanticModelId
Optional model ID. Must identify a model in WorkspaceId. Useful if discovery
is ambiguous or the model has been renamed.
.PARAMETER Refresh
Refresh the discovered or explicitly specified semantic model, then wait for
successful completion before calculating costs. Default: no refresh.
.EXAMPLE
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001'
.EXAMPLE
$result = .\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001' -Days 7 -PricePerCU 0.15
$result.Capacities | Format-Table CapacityName, EstimatedOverageCUHours, EstimatedCost, DataStatus
$result.Daily | Export-Csv -LiteralPath '.\overage-by-day.csv' -NoTypeInformation
.EXAMPLE
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001' -SemanticModelId '00000000-0000-0000-0000-000000000002'
.EXAMPLE
.\Get-FabricCapacityOverageCost.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000001' -Refresh
.LINK
https://learn.microsoft.com/fabric/enterprise/capacity-overage-overview
.LINK
https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries
.LINK
https://learn.microsoft.com/fabric/enterprise/metrics-app-compute-page
.LINK
https://github.com/microsoft/fabric-toolbox/tree/main/monitoring/query-capacity-correlation
.LINK
https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group
.LINK
https://learn.microsoft.com/rest/api/power-bi/datasets/get-refresh-history-in-group
#>
[CmdletBinding()]
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

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OverageToken = $null
$script:TokenAcquiredAt = [datetime]::MinValue
$script:OverageMultiplier = [decimal] 3
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-OptionalProperty {
    param([object] $InputObject, [string] $Name)
    if ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            if ($property.Value -is [array]) { return $property.Value }
            # Preserve enumerable metadata objects, such as HTTP headers.
            return ,$property.Value
        }
    }
}

function Get-QueryField {
    param([object] $Row, [string] $Name)
    foreach ($key in @("[$Name]", $Name)) {
        $property = $Row.PSObject.Properties[$key]
        if ($null -ne $property) { return $property.Value }
    }
    throw "Query result is missing '$Name'. The Metrics App schema or response is incompatible."
}

function ConvertTo-MetricNumber {
    param([object] $Value, [string] $Name)
    $number = [decimal] 0
    $text = [System.Convert]::ToString($Value, $script:InvariantCulture)
    if ($null -eq $Value -or -not [decimal]::TryParse(
        $text, [System.Globalization.NumberStyles]::Float,
        $script:InvariantCulture, [ref] $number
    ) -or $number -lt 0) {
        throw "Invalid or missing nonnegative numeric metric '$Name': '$text'. No cost was inferred."
    }
    return $number
}

function ConvertTo-ModelTime {
    param([object] $Value)
    $time = [datetime]::MinValue
    # Invoke-RestMethod can deserialize ISO strings as DateTime. Avoid a
    # culture-dependent string round trip and preserve the model's clock.
    if ($Value -is [datetime]) {
        $time = $Value
    }
    elseif ($Value -is [datetimeoffset]) {
        $time = $Value.DateTime
    }
    elseif (-not [datetime]::TryParseExact(
        [string] $Value, "yyyy-MM-ddTHH:mm:ss", $script:InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref] $time
    )) {
        throw "Invalid model timestamp '$Value'. Expected yyyy-MM-ddTHH:mm:ss in the app's clock."
    }
    return [datetime]::SpecifyKind($time, [System.DateTimeKind]::Unspecified)
}

function ConvertTo-DaxTime {
    param([datetime] $Time)
    return "DATE($($Time.Year),$($Time.Month),$($Time.Day)) + TIME($($Time.Hour),$($Time.Minute),$($Time.Second))"
}

function Get-OverageAccessToken {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($null -ne (Get-Command az -ErrorAction SilentlyContinue)) {
        try {
            # Capture native stderr without letting Windows PowerShell turn it
            # into a terminating error before the CLI exit code can be checked.
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $nativeOutput = & az account get-access-token --resource 'https://analysis.windows.net/powerbi/api' --output json --only-show-errors 2>&1
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $savedPreference }
            if ($exitCode -ne 0) {
                throw 'Azure CLI could not acquire a Power BI token. Run az login --tenant <tenant-id>.'
            }
            $tokenResult = ($nativeOutput -join [Environment]::NewLine) | ConvertFrom-Json
            $token = Get-OptionalProperty $tokenResult 'accessToken'
            if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI returned no access token.' }
            Write-Verbose 'Authenticated through Azure CLI.'
            return [string] $token
        }
        catch {
            # Never include the native token response in an error or log.
            $failures.Add('Azure CLI authentication failed; run az login --tenant <tenant-id>.')
            Write-Verbose $failures[$failures.Count - 1]
        }
    }
    if ($null -ne (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        try {
            $context = Get-AzContext -ErrorAction Stop
            if ($null -eq $context -or $null -eq $context.Account) {
                throw 'No authenticated Az.Accounts context.'
            }
            $result = Get-AzAccessToken -ResourceUrl 'https://analysis.windows.net/powerbi/api' -ErrorAction Stop
            if ($result.Token -is [System.Security.SecureString]) {
                $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($result.Token)
                try { $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
            }
            else { $token = [string] $result.Token }
            if ([string]::IsNullOrWhiteSpace($token)) { throw 'Az.Accounts returned no access token.' }
            Write-Verbose 'Authenticated through Az.Accounts.'
            return $token
        }
        catch {
            $failures.Add("Az.Accounts authentication failed: $($_.Exception.Message). Run Connect-AzAccount -Tenant <tenant-id>.")
        }
    }
    if ($failures.Count -eq 0) {
        throw 'Install Azure CLI or Az.Accounts, then authenticate with az login or Connect-AzAccount. No other module is required.'
    }
    throw ($failures -join [Environment]::NewLine)
}

function Invoke-OverageApi {
    param(
        [ValidateSet('Get', 'Post')] [string] $Method,
        [string] $Path,
        [string] $Body,
        [switch] $PassThruResponse,
        [switch] $NoRetry
    )
    $refreshedAfterUnauthorized = $false
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        if ($null -eq $script:OverageToken -or [datetime]::UtcNow - $script:TokenAcquiredAt -gt [timespan]::FromMinutes(40)) {
            $script:OverageToken = Get-OverageAccessToken
            $script:TokenAcquiredAt = [datetime]::UtcNow
        }
        $request = @{
            Uri = "https://api.powerbi.com/v1.0/myorg/$Path"
            Method = $Method
            Headers = @{ Authorization = "Bearer $script:OverageToken" }
            TimeoutSec = 180
            ErrorAction = 'Stop'
        }
        if ($Method -eq 'Post') {
            $request.Body = $Body
            $request.ContentType = 'application/json; charset=utf-8'
        }
        try {
            if ($PassThruResponse) { return Invoke-WebRequest -UseBasicParsing @request }
            return Invoke-RestMethod @request
        }
        catch {
            $response = Get-OptionalProperty $_.Exception 'Response'
            $status = Get-OptionalProperty $response 'StatusCode'
            $statusCode = if ($null -ne $status) { [int] $status } else { 0 }
            if ($statusCode -eq 401 -and -not $refreshedAfterUnauthorized -and $attempt -lt 5) {
                $script:OverageToken = $null
                $refreshedAfterUnauthorized = $true
                Write-Verbose 'Power BI returned 401; acquiring a fresh token once.'
                continue
            }
            if (-not $NoRetry -and $statusCode -in @(429, 502, 503, 504) -and $attempt -lt 5) {
                $waitSeconds = [int] [math]::Pow(2, $attempt + 1)
                $headers = Get-OptionalProperty $response 'Headers'
                if ($headers -is [System.Net.WebHeaderCollection]) {
                    $retryAfter = $headers['Retry-After']
                    $seconds = 0
                    if ([int]::TryParse($retryAfter, [ref] $seconds)) {
                        $waitSeconds = [math]::Max($waitSeconds, $seconds)
                    }
                }
                elseif ($null -ne $headers) {
                    $retryAfter = Get-OptionalProperty $headers 'RetryAfter'
                    $delta = Get-OptionalProperty $retryAfter 'Delta'
                    $date = Get-OptionalProperty $retryAfter 'Date'
                    if ($null -ne $delta) {
                        $waitSeconds = [math]::Max($waitSeconds, [int] [math]::Ceiling($delta.TotalSeconds))
                    }
                    elseif ($null -ne $date) {
                        $waitSeconds = [math]::Max($waitSeconds, [int] [math]::Ceiling(($date - [datetimeoffset]::UtcNow).TotalSeconds))
                    }
                }
                Write-Verbose "Power BI returned $statusCode; retrying in $waitSeconds seconds."
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            $detail = if ($null -ne $_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            $hint = if ($statusCode -in @(401, 403) -and $Path -match '/refreshes(?:\?|$)') {
                ' Check the signed-in tenant and workspace access. Refresh history requires model Write permission; triggering refresh also requires Dataset.ReadWrite.All.'
            }
            elseif ($statusCode -in @(401, 403)) {
                ' Check the signed-in tenant, workspace access, model Read/Build permissions, and the tenant Execute Queries setting. App data-source credentials must have capacity-admin access. Service principals cannot query models with RLS or SSO.'
            }
            else { '' }
            if ($NoRetry -and $Method -eq 'Post') {
                $hint += ' This submission was not automatically retried. After a transport/server error, check model refresh history before resubmitting because the service might already have accepted it.'
            }
            $exception = [System.InvalidOperationException]::new("Power BI $Method $Path failed (HTTP $statusCode): $detail$hint")
            $exception.Data['HttpStatusCode'] = $statusCode
            throw $exception
        }
    }
    throw "Power BI $Method $Path exhausted its retry budget."
}

function ConvertTo-RefreshUtcTime {
    param([object] $Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    $time = [datetimeoffset]::MinValue
    if ([string] $Value -notmatch '^\d{4}-\d{2}-\d{2}T' -or -not [datetimeoffset]::TryParse(
        [string] $Value, $script:InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal),
        [ref] $time
    )) {
        throw "Invalid refresh-history UTC timestamp '$Value'. Refresh freshness was not inferred."
    }
    return $time.UtcDateTime
}

function Get-OverageRefreshHistory {
    param([guid] $ModelId)
    $response = Invoke-OverageApi -Method Get -Path "groups/$WorkspaceId/datasets/$ModelId/refreshes?`$top=60"
    $property = $response.PSObject.Properties['value']
    if ($null -eq $property -or $null -eq $property.Value) {
        throw 'Refresh-history response is missing its entries array. Refresh status is unknown.'
    }
    return $property.Value
}

function Get-OverageModelFreshness {
    [CmdletBinding()]
    param([guid] $ModelId, [datetime] $NowUtc = [datetime]::UtcNow)
    $freshness = [pscustomobject] @{
        LastSuccessfulRefreshUtc = $null
        AgeHours = $null
        Status = 'Unknown'
    }
    try { $history = @(Get-OverageRefreshHistory -ModelId $ModelId) }
    catch [System.InvalidOperationException] {
        if ($_.Exception.Data['HttpStatusCode'] -ne 403) { throw }
        Write-Warning 'Cannot read model refresh history without model Write permission. Refresh age is Unknown; usage/debt timestamps will still be checked. No automatic refresh was requested.'
        return $freshness
    }
    $completed = @(foreach ($entry in $history) {
        if ((Get-OptionalProperty $entry 'status') -eq 'Completed') {
            ConvertTo-RefreshUtcTime (Get-OptionalProperty $entry 'endTime')
        }
    })
    if ($completed.Count -eq 0) {
        Write-Warning 'No successful model refresh is recorded in the available history. Refresh age is Unknown; use -Refresh to explicitly request a refresh.'
        return $freshness
    }
    $freshness.LastSuccessfulRefreshUtc = $completed | Sort-Object -Descending | Select-Object -First 1
    $freshness.AgeHours = [math]::Max([double] 0, ($NowUtc - $freshness.LastSuccessfulRefreshUtc).TotalHours)
    $freshness.Status = if ($freshness.AgeHours -gt 12) { 'Stale' } else { 'Recent' }
    if ($freshness.Status -eq 'Stale') {
        Write-Warning "The model's last successful refresh is $([math]::Round($freshness.AgeHours, 2)) hours old (over 12 hours). No automatic refresh is performed; use -Refresh to request one."
    }
    return $freshness
}

function Start-OverageModelRefresh {
    param(
        [guid] $ModelId,
        [int] $TimeoutSeconds = 7200,
        [int] $PollIntervalSeconds = 10
    )
    $path = "groups/$WorkspaceId/datasets/$ModelId/refreshes"
    # Retrying a refresh submission after an ambiguous HTTP failure can
    # schedule another refresh and consume quota. Do not retry transient
    # submission errors; a rejected 401 can still retry with a new token.
    $response = Invoke-OverageApi -Method Post -Path $path -Body '{"notifyOption":"NoNotification"}' -PassThruResponse -NoRetry
    if ([int] $response.StatusCode -ne 202) {
        throw "Refresh submission returned unexpected HTTP $($response.StatusCode). Check model refresh history before resubmitting."
    }
    $location = [string] (@($response.Headers['Location']) | Select-Object -First 1)
    $requestText = [string] (@($response.Headers['x-ms-request-id']) | Select-Object -First 1)
    if ($location -match '/refreshes/([0-9a-fA-F-]{36})(?:\?.*)?$') { $requestText = $Matches[1] }
    $requestId = [guid]::Empty
    if (-not [guid]::TryParse($requestText, [ref] $requestId) -or $requestId -eq [guid]::Empty) {
        throw 'Refresh was accepted, but no trackable request ID was returned. Check model refresh history before resubmitting; no second refresh was requested.'
    }
    Write-Verbose "Requested model refresh $requestId. Waiting for completion."
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $history = @(Get-OverageRefreshHistory -ModelId $ModelId)
        $matching = @($history | Where-Object { (Get-OptionalProperty $_ 'requestId') -eq $requestId.ToString('D') })
        if ($matching.Count -gt 1) { throw "Refresh history contains duplicate entries for request $requestId." }
        if ($matching.Count -eq 1) {
            $entry = $matching[0]
            $status = [string] (Get-OptionalProperty $entry 'status')
            if ($status -eq 'Completed') {
                $completedAt = ConvertTo-RefreshUtcTime (Get-OptionalProperty $entry 'endTime')
                Write-Verbose "Model refresh $requestId completed at $($completedAt.ToString('o'))."
                return [pscustomobject] @{ RequestId = $requestId; CompletedAtUtc = $completedAt }
            }
            if ($status -in @('Failed', 'Disabled', 'Cancelled', 'Canceled')) {
                $detail = [string] (Get-OptionalProperty $entry 'serviceExceptionJson')
                throw "Model refresh $requestId ended with status '$status'. $detail No costs were calculated."
            }
            if ($status -notin @('Unknown', 'InProgress', 'NotStarted', 'Queued')) {
                throw "Model refresh $requestId returned unrecognized status '$status'. No costs were calculated."
            }
        }
        $remaining = $TimeoutSeconds - $timer.Elapsed.TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Seconds ([math]::Min([double] $PollIntervalSeconds, $remaining)) }
    }
    throw "Timed out waiting for model refresh $requestId after $TimeoutSeconds seconds. The refresh was not cancelled and may still be running. Check model refresh history before resubmitting; no costs were calculated."
}

function Invoke-OverageDax {
    param([guid] $ModelId, [string] $Query)
    $body = @{
        queries = @(@{ query = $Query })
        serializerSettings = @{ includeNulls = $true }
    } | ConvertTo-Json -Depth 6 -Compress
    $response = Invoke-OverageApi -Method Post -Path "datasets/$ModelId/executeQueries" -Body $body
    $errorObject = Get-OptionalProperty $response 'error'
    if ($null -ne $errorObject) { throw "DAX response error: $($errorObject | ConvertTo-Json -Depth 10 -Compress)" }
    $results = @(Get-OptionalProperty $response 'results')
    if ($results.Count -ne 1) { throw 'DAX response did not contain exactly one query result.' }
    $errorObject = Get-OptionalProperty $results[0] 'error'
    if ($null -ne $errorObject) { throw "DAX query error: $($errorObject | ConvertTo-Json -Depth 10 -Compress)" }
    $tables = @(Get-OptionalProperty $results[0] 'tables')
    if ($tables.Count -ne 1) { throw 'DAX response did not contain exactly one result table.' }
    $errorObject = Get-OptionalProperty $tables[0] 'error'
    if ($null -ne $errorObject) { throw "DAX table error: $($errorObject | ConvertTo-Json -Depth 10 -Compress)" }
    $rowsProperty = $tables[0].PSObject.Properties['rows']
    if ($null -eq $rowsProperty -or $null -eq $rowsProperty.Value) {
        throw 'DAX response has no rows array. An incomplete response is not a zero-cost result.'
    }
    return $rowsProperty.Value
}

function Get-OverageModel {
    param([object[]] $Models, [guid] $RequestedId)
    if ($RequestedId -ne [guid]::Empty) {
        $matches = @($Models | Where-Object { [guid] $_.id -eq $RequestedId })
        if ($matches.Count -ne 1) { throw "SemanticModelId $RequestedId is not accessible in workspace $WorkspaceId." }
        return $matches[0]
    }
    $matches = @($Models | Where-Object {
        $_.name -match '(?i)(Fabric|Premium).*Capacity.*Metrics|Capacity.*Metrics'
    })
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -eq 0 -and $Models.Count -eq 1) { return $Models[0] }
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
    # FORMAT deliberately removes the two unrelated columns' data lineage so
    # NATURALLEFTOUTERJOIN can safely join them on one identical timestamp key.
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

function Get-OverageReplay {
    param(
        [object[]] $Samples,
        [datetime[]] $ResetTimes,
        [datetime] $Start,
        [datetime] $End,
        [decimal] $Rate,
        [datetime[]] $InactiveTimes = @()
    )
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
            ExpectedTimepoints = [int] (($dayEnd - $dayStart).TotalSeconds / 30)
        }
    }
    $debt = [decimal] 0
    $initialDebt = [decimal] 0
    $previous = $null
    $missing = 0
    $ineligible = 0
    $count = 0
    $first = $null
    $last = $null
    foreach ($sample in $ordered) {
        if ($sample.Timepoint -lt $Start.AddSeconds(-30) -or $sample.Timepoint -ge $End -or $sample.Timepoint.Second -notin @(0, 30)) {
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
            $missing += [int] ($gap / 30)
            if (-not $reset -and ($debt -gt 0 -or $previous.RecordedCarry -gt 0)) {
                throw "Missing timepoints while debt is outstanding at $($sample.Timepoint). Cannot reliably replay burndown/payments across this gap."
            }
        }
        if ($inactive) { $debt = [decimal] 0 }
        elseif ($reset) {
            # Creation/resume removes old debt, but new work in that same
            # timepoint must still be eligible for overage.
            $debt = $sample.RecordedCarry + $sample.RecordedBilled
        }
        elseif ($null -eq $previous -or $gap -gt 0) {
            $debt = $sample.RecordedCarry + $sample.RecordedBilled
            if ($count -eq 0) {
                $initialDebt = [math]::Max([decimal] 0, $debt - $sample.Add + $sample.Burndown)
            }
        }
        else {
            $expectedHistorical = [math]::Max([decimal] 0, $previous.RecordedCarry + $sample.Add - $sample.Burndown - $sample.RecordedBilled)
            $tolerance = [math]::Max([decimal] 0.01, $sample.RecordedCarry * [decimal] 0.000001)
            if ([math]::Abs($expectedHistorical - $sample.RecordedCarry) -gt $tolerance) {
                throw "Unexplained carry-forward discontinuity at $($sample.Timepoint): expected $expectedHistorical CU-s, got $($sample.RecordedCarry). Billing timing/schema differs or data is incomplete; no cost was inferred."
            }
            # Historical burndown can be zero after a recorded payment even
            # when idle capacity can still pay down the counterfactual debt.
            $burndown = [math]::Max($sample.Burndown, $sample.AvailableBurndown)
            $debt = [math]::Max([decimal] 0, $debt + $sample.Add - $burndown)
        }
        if ($sample.Timepoint -lt $Start) {
            # A warm-up row initializes existing debt, not a payment outside
            # the requested window. Actual pre-window payments stay paid.
            $debt = if ($inactive) { [decimal] 0 } else { $sample.RecordedCarry }
            $initialDebt = $debt
            $previous = $sample
            continue
        }
        $bucket = $daily[$sample.Timepoint.ToString('yyyy-MM-dd')]
        if ($count -eq 0) {
            $first = $sample.Timepoint
            $missing += [int] (($first - $Start).TotalSeconds / 30)
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
    $missing += [int] (($End - $last.AddSeconds(30)).TotalSeconds / 30)
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

try {
    $datasetResponse = Invoke-OverageApi -Method Get -Path "groups/$WorkspaceId/datasets"
    $models = @(Get-OptionalProperty $datasetResponse 'value')
    if ($models.Count -eq 0) { throw "No semantic models are accessible in workspace $WorkspaceId." }
    $requestedId = if ($PSBoundParameters.ContainsKey('SemanticModelId')) { $SemanticModelId } else { [guid]::Empty }
    $model = Get-OverageModel -Models $models -RequestedId $requestedId
    $modelId = [guid] $model.id
    Write-Verbose "Using semantic model '$($model.name)' [$modelId]."

    $refreshResult = $null
    if ($Refresh) { $refreshResult = Start-OverageModelRefresh -ModelId $modelId }
    $modelFreshness = Get-OverageModelFreshness -ModelId $modelId

    $parameters = Invoke-OverageApi -Method Get -Path "groups/$WorkspaceId/datasets/$modelId/parameters"
    $offsetParameters = @((Get-OptionalProperty $parameters 'value') | Where-Object { $_.name -eq 'UTC_offset' })
    if ($offsetParameters.Count -ne 1) {
        throw "Could not discover the model's UTC_offset. Use a current, configured Capacity Metrics App model; timezone was not guessed."
    }
    $offset = [double] 0
    if (-not [double]::TryParse(
        [string] $offsetParameters[0].currentValue, [System.Globalization.NumberStyles]::Float,
        $script:InvariantCulture, [ref] $offset
    ) -or [double]::IsNaN($offset) -or $offset -lt -12 -or $offset -gt 14) {
        throw "Invalid Metrics App UTC_offset '$($offsetParameters[0].currentValue)'."
    }
    $modelNow = [datetime]::SpecifyKind([datetime]::UtcNow.AddHours($offset), [System.DateTimeKind]::Unspecified)
    $modelNow = $modelNow.AddTicks(-($modelNow.Ticks % [timespan]::FromSeconds(30).Ticks))
    $capacityQuery = @'
EVALUATE
    SELECTCOLUMNS('Capacities',
        "CapacityId", 'Capacities'[Capacity Id],
        "CapacityName", 'Capacities'[Capacity name],
        "SKU", 'Capacities'[SKU])
'@
    $capacityRows = @(Invoke-OverageDax -ModelId $modelId -Query $capacityQuery)
    $capacities = @(foreach ($row in $capacityRows) {
        [pscustomobject] @{
            Id = [guid] (Get-QueryField $row 'CapacityId')
            Name = [string] (Get-QueryField $row 'CapacityName')
            SKU = [string] (Get-QueryField $row 'SKU')
        }
    })
    $eligible = @($capacities | Where-Object { $_.SKU -match '^F[1-9][0-9]*$' } | Sort-Object Id -Unique)
    $skipped = @($capacities | Where-Object { $_.SKU -notmatch '^F[1-9][0-9]*$' })
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
        $bounds = @(Invoke-OverageDax -ModelId $modelId -Query $query)
        if ($bounds.Count -ne 1) { throw "Could not determine data bounds for '$($capacity.Name)'." }
        $usageText = Get-QueryField $bounds[0] 'LastUsage'
        $debtText = Get-QueryField $bounds[0] 'LastDebt'
        if ([string]::IsNullOrWhiteSpace($usageText) -or [string]::IsNullOrWhiteSpace($debtText)) {
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
    $end = ($latestTimes | Sort-Object -Descending | Select-Object -First 1)
    if ($end -gt $modelNow) { $end = $modelNow }
    $start = $end.AddDays(-$Days)
    $metricsAgeHours = [math]::Max([double] 0, ($modelNow - $end).TotalHours)
    if ($metricsAgeHours -gt 12) {
        Write-Warning "Latest available usage/debt data is $([math]::Round($metricsAgeHours, 2)) hours old (over 12 hours). The estimate ends at $($end.ToString('s')) in the app's clock, NOT now. Model refresh does not create new activity for idle or paused capacities."
    }
    $rate = $PricePerCU * $script:OverageMultiplier
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
        $resetRows = @(Invoke-OverageDax -ModelId $modelId -Query $resetQuery)
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
            $rows = @(Invoke-OverageDax -ModelId $modelId -Query $query)
            foreach ($row in $rows) {
                $expected = ConvertTo-MetricNumber (Get-QueryField $row 'ExpectedRows') 'ExpectedRows'
                if ($expected -ne $rows.Count) {
                    throw "Truncated DAX response for '$($capacity.Name)': expected $expected rows, received $($rows.Count). No partial query was accepted."
                }
            }
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
        OverageMultiplier = $script:OverageMultiplier
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
finally { $script:OverageToken = $null }
