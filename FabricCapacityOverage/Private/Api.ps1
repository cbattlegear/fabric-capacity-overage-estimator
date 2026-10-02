function Get-OverageRetryDelay {
    param([object] $Response, [int] $Attempt)
    $waitSeconds = [int] [math]::Pow(2, $Attempt + 1)
    $headers = Get-OptionalProperty $Response 'Headers'
    if ($headers -is [System.Net.WebHeaderCollection]) {
        $retryAfter = $headers['Retry-After']
        $seconds = 0
        $date = [datetimeoffset]::MinValue
        if ([int]::TryParse($retryAfter, [ref] $seconds)) {
            $waitSeconds = [math]::Max($waitSeconds, $seconds)
        }
        elseif ([datetimeoffset]::TryParse(
            $retryAfter, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $date
        )) {
            $waitSeconds = [math]::Max($waitSeconds, [int] [math]::Ceiling(($date.UtcDateTime - (Get-OverageUtcNow)).TotalSeconds))
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
            $waitSeconds = [math]::Max($waitSeconds, [int] [math]::Ceiling(($date.UtcDateTime - (Get-OverageUtcNow)).TotalSeconds))
        }
    }
    return $waitSeconds
}

function Invoke-OverageApi {
    param(
        [hashtable] $Context,
        [ValidateSet('Get', 'Post')] [string] $Method,
        [string] $Path,
        [string] $Body,
        [switch] $PassThruResponse,
        [switch] $NoRetry
    )
    $refreshedAfterUnauthorized = $false
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $now = Get-OverageUtcNow
        if ($null -eq $Context.Token -or $now - $Context.TokenAcquiredAt -gt [timespan]::FromMinutes(40)) {
            $Context.Token = Get-OverageAccessToken
            $Context.TokenAcquiredAt = $now
        }
        $request = @{
            Uri = "https://api.powerbi.com/v1.0/myorg/$Path"
            Method = $Method
            Headers = @{ Authorization = "Bearer $($Context.Token)" }
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
                $Context.Token = $null
                $refreshedAfterUnauthorized = $true
                Write-Verbose 'Power BI returned 401; acquiring a fresh token once.'
                continue
            }
            if (-not $NoRetry -and $statusCode -in @(429, 502, 503, 504) -and $attempt -lt 5) {
                $waitSeconds = Get-OverageRetryDelay -Response $response -Attempt $attempt
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

function Invoke-OverageDax {
    param([hashtable] $Context, [guid] $ModelId, [string] $Query)
    $body = @{
        queries = @(@{ query = $Query })
        serializerSettings = @{ includeNulls = $true }
    } | ConvertTo-Json -Depth 6 -Compress
    $response = Invoke-OverageApi -Context $Context -Method Post -Path "datasets/$ModelId/executeQueries" -Body $body
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
    if ($null -eq $rowsProperty -or $rowsProperty.Value -isnot [array]) {
        throw 'DAX response has no rows array. An incomplete response is not a zero-cost result.'
    }
    return $rowsProperty.Value
}
