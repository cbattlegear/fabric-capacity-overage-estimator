function Initialize-TestType {
    param([string] $FixtureRoot)
    if ($null -eq ('FabricCapacityOverage.Tests.HttpException' -as [type])) {
        Add-Type -Path (Join-Path $FixtureRoot 'TestTypes.cs') -ErrorAction Stop
    }
}

function Get-TestContext {
    return @{
        WorkspaceId = [guid] '11111111-1111-1111-1111-111111111111'
        Token = $null
        TokenAcquiredAt = [datetime]::MinValue
    }
}

function Get-TestSample {
    param(
        [datetime] $Timepoint = [datetime] '2026-10-01T00:00:00',
        [decimal] $Carry = 0,
        [decimal] $Add = 0,
        [decimal] $Burn = 0,
        [decimal] $Delay = 0,
        [decimal] $Billed = 0,
        [decimal] $BaseCU = 16,
        [decimal] $Available = 0,
        [string] $SKU = 'F16'
    )
    return [pscustomobject] @{
        Timepoint = [datetime]::SpecifyKind($Timepoint, [System.DateTimeKind]::Unspecified)
        RecordedCarry = $Carry
        Add = $Add
        Burndown = $Burn
        DelayRatio = $Delay
        RecordedBilled = $Billed
        BaseCU = $BaseCU
        AvailableBurndown = $Available
        SKU = $SKU
    }
}

function Get-TestDaxResponse {
    param([object[]] $Rows = @())
    return [pscustomobject] @{
        results = @([pscustomobject] @{
            tables = @([pscustomobject] @{ rows = $Rows })
        })
    }
}

function Get-TestDaxWindow {
    param([string] $Query)
    $dateMatches = [regex]::Matches($Query, 'DATE\((\d+),(\d+),(\d+)\) \+ TIME\((\d+),(\d+),(\d+)\)')
    if ($dateMatches.Count -lt 2) { throw 'The series query fixture needs explicit start/end DAX boundaries.' }
    return @(foreach ($match in @($dateMatches[0], $dateMatches[1])) {
        [datetime]::new(
            [int] $match.Groups[1].Value, [int] $match.Groups[2].Value, [int] $match.Groups[3].Value,
            [int] $match.Groups[4].Value, [int] $match.Groups[5].Value, [int] $match.Groups[6].Value
        )
    })
}

function Invoke-TestApiResponse {
    param(
        [object] $Fixture,
        [System.Collections.Generic.List[object]] $Requests,
        [string] $Uri,
        [string] $Method,
        [string] $Body,
        [hashtable] $Headers
    )
    $Requests.Add([pscustomobject] @{ Uri = $Uri; Method = $Method; Body = $Body; Authorization = $Headers.Authorization })
    if ($Method -eq 'Get' -and $Uri -match '/datasets$') { return $Fixture.datasets }
    if ($Method -eq 'Get' -and $Uri -match '/parameters$') { return $Fixture.parameters }
    if ($Method -eq 'Get' -and $Uri -match '/refreshes\?') { return $Fixture.refreshHistory }
    if ($Method -ne 'Post' -or $Uri -notmatch '/executeQueries$') { throw "Unexpected offline fixture request: $Method $Uri" }
    $query = ($Body | ConvertFrom-Json).queries[0].query
    if ($query -match "SELECTCOLUMNS\('Capacities'") { return Get-TestDaxResponse -Rows $Fixture.capacities }
    if ($query -notmatch "MPARAMETER 'CapacitiesList' = \{ ""([0-9A-F-]+)"" \}") {
        throw 'Every capacity-scoped query must set the CapacitiesList DirectQuery parameter.'
    }
    $capacityId = $Matches[1].ToLowerInvariant()
    if ($query -match '"LastUsage"') {
        $bounds = $Fixture.bounds.PSObject.Properties[$capacityId]
        if ($null -eq $bounds) { throw "No bounds fixture for capacity $capacityId" }
        return Get-TestDaxResponse -Rows @($bounds.Value)
    }
    if ($query -match "'System Events'") { return Get-TestDaxResponse -Rows $Fixture.resets }
    $window = Get-TestDaxWindow -Query $query
    $rows = @($Fixture.series | Where-Object {
        $time = ConvertTo-ModelTime $_.'[Timepoint]'
        $time -ge $window[0] -and $time -lt $window[1]
    } | ForEach-Object {
        $copy = $_ | Select-Object *
        $copy | Add-Member -NotePropertyName '[ExpectedRows]' -NotePropertyValue 0
        $copy
    })
    foreach ($row in $rows) { $row.'[ExpectedRows]' = $rows.Count }
    if ($Fixture.truncate -and $rows.Count -gt 0) { $rows = @($rows | Select-Object -Skip 1) }
    return Get-TestDaxResponse -Rows $rows
}
