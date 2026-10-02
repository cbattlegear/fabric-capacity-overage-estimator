function Get-OverageRefreshHistory {
    param([hashtable] $Context, [guid] $ModelId)
    $response = Invoke-OverageApi -Context $Context -Method Get -Path "groups/$($Context.WorkspaceId)/datasets/$ModelId/refreshes?`$top=60"
    $property = $response.PSObject.Properties['value']
    if ($null -eq $property -or $property.Value -isnot [array]) {
        throw 'Refresh-history response is missing its entries array. Refresh status is unknown.'
    }
    return $property.Value
}

function Get-OverageModelFreshness {
    [CmdletBinding()]
    param([hashtable] $Context, [guid] $ModelId, [datetime] $NowUtc = (Get-OverageUtcNow))
    $freshness = [pscustomobject] @{
        LastSuccessfulRefreshUtc = $null
        AgeHours = $null
        Status = 'Unknown'
    }
    try { $history = @(Get-OverageRefreshHistory -Context $Context -ModelId $ModelId) }
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
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [hashtable] $Context,
        [guid] $ModelId,
        [ValidateRange(0, 7200)] [int] $TimeoutSeconds = 7200,
        [ValidateRange(1, 600)] [int] $PollIntervalSeconds = 10
    )
    if (-not $PSCmdlet.ShouldProcess("semantic model $ModelId in workspace $($Context.WorkspaceId)", 'Refresh semantic model')) {
        return
    }
    $path = "groups/$($Context.WorkspaceId)/datasets/$ModelId/refreshes"
    # An ambiguous submission failure may already have scheduled a refresh.
    # Only a rejected 401 is safe to retry with a replacement token.
    $response = Invoke-OverageApi -Context $Context -Method Post -Path $path -Body '{"notifyOption":"NoNotification"}' -PassThruResponse -NoRetry
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
        $history = @(Get-OverageRefreshHistory -Context $Context -ModelId $ModelId)
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
