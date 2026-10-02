BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
}

InModuleScope FabricCapacityOverage -Parameters @{ FixtureRoot = (Join-Path $PSScriptRoot 'Fixtures') } {
    param($FixtureRoot)
    $script:TestFixtureRoot = $FixtureRoot

    Describe 'Public command with deterministic HTTP, token and clock fixtures' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
            Initialize-TestType -FixtureRoot $script:TestFixtureRoot
            $script:ApiBody = (Get-Command Invoke-OverageApi).ScriptBlock
        }
        BeforeEach {
            $script:Fixture = Get-Content -LiteralPath (Join-Path $script:TestFixtureRoot 'metrics-api.json') -Raw | ConvertFrom-Json
            $script:Requests = [System.Collections.Generic.List[object]]::new()
            $script:Contexts = [System.Collections.Generic.List[object]]::new()
            $script:TokenCalls = 0
            Mock Get-OverageUtcNow { ConvertTo-RefreshUtcTime $script:Fixture.nowUtc }
            Mock Get-OverageAccessToken { $script:TokenCalls++; "offline-invocation-$script:TokenCalls" }
            Mock Start-Sleep { throw 'The completed offline refresh fixture must not sleep.' }
            Mock Invoke-OverageApi {
                $script:Contexts.Add($Context)
                & $script:ApiBody -Context $Context -Method $Method -Path $Path -Body $Body -PassThruResponse:$PassThruResponse -NoRetry:$NoRetry
            }
            Mock Invoke-RestMethod {
                Invoke-TestApiResponse -Fixture $script:Fixture -Requests $script:Requests -Uri $Uri -Method $Method -Body $Body -Headers $Headers
            }
            Mock Invoke-WebRequest {
                if ($Method -ne 'Post' -or $Uri -notmatch '/refreshes$') { throw "Unexpected offline web request: $Method $Uri" }
                $script:Requests.Add([pscustomobject] @{ Uri = $Uri; Method = $Method; Body = $Body; Authorization = $Headers.Authorization })
                [pscustomobject] @{
                    StatusCode = 202
                    Headers = @{ Location = "$Uri/$($script:Fixture.requestId)" }
                }
            }
        }

        It 'returns one structured object with original defaults and separate recorded charges' {
            $objects = @(Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -WarningAction SilentlyContinue)
            $objects.Count | Should -Be 1
            $result = $objects[0]
            $result | Should -BeOfType ([pscustomobject])
            $result.RequestedDays | Should -Be 14
            $result.BasePricePerCUHour | Should -BeOfType ([decimal])
            $result.BasePricePerCUHour | Should -Be ([decimal] '0.18')
            $result.OverageMultiplier | Should -Be ([decimal] 3)
            $result.OveragePricePerCUHour | Should -Be ([decimal] '0.54')
            $result.RefreshRequested | Should -BeFalse
            $result.SemanticModelId | Should -Be ([guid] $script:Fixture.modelId)
            $result.Capacities[0].EstimatedCost | Should -Be ([decimal] '0.57')
            $result.Capacities[0].RecordedCostAtSuppliedPrice | Should -Be ([decimal] '0.57')
            $result.Capacities[0].PaymentEvents | Should -Be 2
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'reports missing capacity totals as null with known-data subtotals, not zero' {
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.DataStatus | Should -Be 'Partial'
            $result.EstimatedCost | Should -BeNullOrEmpty
            $result.EstimatedOverageCUHours | Should -BeNullOrEmpty
            $result.RecordedCostAtSuppliedPrice | Should -BeNullOrEmpty
            $result.RecordedOverageCUHours | Should -BeNullOrEmpty
            $result.EstimatedCostForCapacitiesWithData | Should -Be ([decimal] '0.57')
            $result.RecordedCostForCapacitiesWithDataAtSuppliedPrice | Should -Be ([decimal] '0.57')
            $result.MissingDataCapacities.Count | Should -Be 1
            $result.MissingDataCapacities[0].Name | Should -Be 'Missing capacity'
            $result.SkippedNonFCapacities.Count | Should -Be 1
            $result.Capacities[0].MissingTimepoints | Should -Be 2877
        }

        It 'totals only known capacities when none are missing and retains Partial coverage' {
            $script:Fixture.capacities = @($script:Fixture.capacities[0])
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.EstimatedCost | Should -Be ([decimal] '0.57')
            $result.RecordedCostAtSuppliedPrice | Should -Be ([decimal] '0.57')
            $result.EstimatedOverageCUHours | Should -Be ([decimal] '1.055556')
            $result.DataStatus | Should -Be 'Partial'
            $result.MissingDataCapacities.Count | Should -Be 0
        }

        It 'enumerates and scopes every visible F-SKU capacity independently' {
            $script:Fixture.bounds.'44444444-4444-4444-4444-444444444444' = $script:Fixture.bounds.'33333333-3333-3333-3333-333333333333'
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.Capacities.Count | Should -Be 2
            $result.EstimatedCost | Should -Be ([decimal] '1.14')
            $queries = @($script:Requests | Where-Object Method -eq 'Post' | ForEach-Object { ($_.Body | ConvertFrom-Json).queries[0].query })
            @($queries | Where-Object { $_ -match "CapacitiesList.*33333333-3333-3333-3333-333333333333" }).Count | Should -BeGreaterThan 0
            @($queries | Where-Object { $_ -match "CapacitiesList.*44444444-4444-4444-4444-444444444444" }).Count | Should -BeGreaterThan 0
        }

        It 'uses app-clock daily chunks, a warm-up point and an exclusive final boundary' {
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 14 -WarningAction SilentlyContinue
            $result.ModelUTCOffsetHours | Should -Be -5.5
            $result.WindowEndModelTimeExclusive.ToString('s') | Should -Be '2026-10-02T12:30:00'
            $result.WindowEndModelTimeExclusive.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
            $windows = @($script:Requests | Where-Object Method -eq 'Post' | ForEach-Object {
                $query = ($_.Body | ConvertFrom-Json).queries[0].query
                if ($query -match 'VAR UsageRows') { ,(Get-TestDaxWindow -Query $query) }
            })
            $windows.Count | Should -Be 15
            $windows[0][0] | Should -Be $result.WindowStartModelTime.AddSeconds(-30)
            $windows[-1][1] | Should -Be $result.WindowEndModelTimeExclusive
            for ($index = 0; $index -lt $windows.Count; $index++) {
                ($windows[$index][1] - $windows[$index][0]).TotalHours | Should -BeLessOrEqual 24
                if ($index -gt 0) { $windows[$index][0] | Should -Be $windows[$index - 1][1] }
            }
        }

        It 'does not include a latest incomplete timepoint even if it contains a very large charge' {
            $extra = $script:Fixture.series[0] | Select-Object *
            $extra.'[Timepoint]' = '2026-10-02T12:30:00'
            $extra.'[RecordedBilledCUSeconds]' = 1000000
            $script:Fixture.series = @($script:Fixture.series) + @($extra)
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.Capacities[0].Timepoints | Should -Be 3
            $result.Capacities[0].RecordedCostAtSuppliedPrice | Should -Be ([decimal] '0.57')
        }

        It 'retains typed model timestamps without local timezone conversion' -TestCases @(
            @{ Kind = 'Utc' }, @{ Kind = 'Local' }, @{ Kind = 'Offset' }
        ) {
            param($Kind)
            $bounds = $script:Fixture.bounds.'33333333-3333-3333-3333-333333333333'
            if ($Kind -eq 'Offset') {
                $bounds.'[LastUsage]' = [datetimeoffset]::new(2026, 10, 2, 12, 30, 0, [timespan]::FromHours(9))
                $bounds.'[LastDebt]' = $bounds.'[LastUsage]'
            }
            else {
                $bounds.'[LastUsage]' = [datetime]::SpecifyKind([datetime] '2026-10-02T12:30:00', [System.DateTimeKind] $Kind)
                $bounds.'[LastDebt]' = $bounds.'[LastUsage]'
            }
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.WindowEndModelTimeExclusive.ToString('s') | Should -Be '2026-10-02T12:30:00'
            $result.Capacities[0].EstimatedCost | Should -Be ([decimal] '0.57')
        }

        It 'accepts the original aliases and applies only one 3x price multiplier' {
            $result = Get-FabricCapacityOverageCost -CapacityMetricsWorkspaceId $script:Fixture.workspaceId -NumberOfDays 1 -PaygPricePerCUHour 0.15 -WarningAction SilentlyContinue
            $result.RequestedDays | Should -Be 1
            $result.OveragePricePerCUHour | Should -Be ([decimal] '0.45')
            $result.Capacities[0].EstimatedCost | Should -Be ([decimal] '0.48')
        }

        It 'accepts a zero base price without changing the physical debt replay' {
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -PricePerCU 0 -WarningAction SilentlyContinue
            $result.Capacities[0].EstimatedCost | Should -Be 0
            $result.Capacities[0].PaymentEvents | Should -Be 2
            $result.Capacities[0].EstimatedOverageCUHours | Should -BeGreaterThan 0
        }

        It 'honors explicit model selection in the workspace' {
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -SemanticModelId '77777777-7777-7777-7777-777777777777' -Days 1 -WarningAction SilentlyContinue
            $result.SemanticModelName | Should -Be 'Unrelated model'
            @($script:Requests | Where-Object { $_.Uri -match '/datasets/77777777-7777-7777-7777-777777777777/' }).Count | Should -BeGreaterThan 0
        }

        It 'rejects no models and ambiguous models before queries or refresh' {
            $script:Fixture.datasets.value = @()
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Refresh } | Should -Throw '*No semantic models*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'rejects no eligible F-SKU capacity rather than returning zero' {
            $script:Fixture.capacities = @($script:Fixture.capacities[2])
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue } | Should -Throw '*No eligible F-SKU*'
        }

        It 'rejects no observable data for any eligible capacity' {
            $script:Fixture.capacities = @($script:Fixture.capacities[1])
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue } | Should -Throw '*No eligible capacity has observable*'
        }

        It 'rejects conflicting current SKUs for a duplicated capacity ID' {
            $duplicate = $script:Fixture.capacities[0] | Select-Object *
            $duplicate.'[SKU]' = 'F64'
            $script:Fixture.capacities = @($script:Fixture.capacities) + @($duplicate)
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue } | Should -Throw '*Conflicting current capacity metadata*'
        }

        It 'collapses identical capacity metadata without charging it twice' {
            $script:Fixture.capacities = @($script:Fixture.capacities[0], $script:Fixture.capacities[0])
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.Capacities.Count | Should -Be 1
            $result.EstimatedCost | Should -Be ([decimal] '0.57')
        }

        It 'requires a unique model UTC_offset and never guesses timezone' {
            $script:Fixture.parameters.value = @()
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 } | Should -Throw '*Could not discover*UTC_offset*'
        }

        It 'rejects invalid UTC_offset <Value>' -TestCases @(
            @{ Value = '-13' }, @{ Value = '15' }, @{ Value = 'NaN' }, @{ Value = 'Infinity' }, @{ Value = 'unknown' }
        ) {
            param($Value)
            $script:Fixture.parameters.value[0].currentValue = $Value
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 } | Should -Throw '*Invalid Metrics App UTC_offset*'
        }

        It 'warns strictly after twelve hours of metrics age, including fractional seconds' -TestCases @(
            @{ Milliseconds = 0; Status = 'Recent'; WarningCount = 0 },
            @{ Milliseconds = 1; Status = 'Stale'; WarningCount = 1 }
        ) {
            param($Milliseconds, $Status, $WarningCount)
            $script:Fixture.nowUtc = [datetime]::SpecifyKind([datetime] '2026-10-03T06:00:00', [System.DateTimeKind]::Utc).AddMilliseconds($Milliseconds)
            $warnings = @()
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningVariable warnings -WarningAction SilentlyContinue
            $result.MetricsFreshness | Should -Be $Status
            @($warnings | Where-Object { "$_" -match 'Latest available usage/debt data' }).Count | Should -Be $WarningCount
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'reports history 403 as Unknown and still checks metrics/data' {
            Mock Invoke-RestMethod { throw [FabricCapacityOverage.Tests.HttpException]::new(403, $null) } -ParameterFilter { $Uri -match '/refreshes\?' }
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue
            $result.ModelRefreshFreshness | Should -Be 'Unknown'
            $result.ModelRefreshAgeHours | Should -BeNullOrEmpty
            $result.Capacities[0].EstimatedCost | Should -Be ([decimal] '0.57')
        }

        It 'does not swallow history failures unrelated to Write permission' {
            Mock Invoke-RestMethod { throw [FabricCapacityOverage.Tests.HttpException]::new(404, $null) } -ParameterFilter { $Uri -match '/refreshes\?' }
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 } | Should -Throw '*HTTP 404*'
        }

        It 'fails rather than returning a partial success for a truncated query' {
            $script:Fixture.truncate = $true
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue } | Should -Throw '*Truncated DAX response*'
            $script:Contexts[0].Token | Should -BeNullOrEmpty
        }

        It 'does not treat a missing debt join as zero cost' {
            $script:Fixture.series[0].'[RecordedCarryCUSeconds]' = $null
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue } | Should -Throw '*Invalid or missing*RecordedCarryCUSeconds*'
        }

        It 'submits only an explicit refresh and returns its completed request ID' {
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -Refresh -Confirm:$false -WarningAction SilentlyContinue
            $result.RefreshRequested | Should -BeTrue
            $result.RefreshRequestId | Should -Be ([guid] $script:Fixture.requestId)
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            $posts = @($script:Requests | Where-Object { $_.Uri -match '/refreshes$' -and $_.Method -eq 'Post' })
            $posts.Count | Should -Be 1
        }

        It 'does not calculate from old data after refresh fails' {
            $script:Fixture.refreshHistory.value[0].status = 'Failed'
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -Refresh -Confirm:$false } | Should -Throw '*No costs were calculated*'
            @($script:Requests | Where-Object { $_.Uri -match '/executeQueries$' }).Count | Should -Be 0
            $script:Contexts[0].Token | Should -BeNullOrEmpty
        }

        It 'does not calculate after a refresh timeout' {
            Mock Start-OverageModelRefresh { throw 'Offline timeout: refresh not cancelled; no costs were calculated.' }
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Refresh -Confirm:$false } | Should -Throw '*timeout*not cancelled*'
            @($script:Requests | Where-Object { $_.Uri -match '/executeQueries$' }).Count | Should -Be 0
        }

        It 'uses real public WhatIf to stop before refresh, history or cost calculation' {
            $result = @(Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Refresh -WhatIf)
            $result.Count | Should -Be 0
            $script:Requests.Count | Should -Be 1
            $script:Requests[0].Method | Should -Be 'Get'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            $script:Contexts[0].Token | Should -BeNullOrEmpty
        }

        It 'leaves read-only calculation usable with WhatIf when Refresh is absent' {
            $result = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WhatIf -WarningAction SilentlyContinue
            $result.Capacities[0].EstimatedCost | Should -Be ([decimal] '0.57')
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'clears tokens on success without leaking workspace/parameter/preference state between calls' {
            $preference = $ErrorActionPreference
            $confirm = $ConfirmPreference
            $whatIf = $WhatIfPreference
            $first = Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -PricePerCU 0.15 -SemanticModelId $script:Fixture.modelId -WarningAction SilentlyContinue
            $firstContext = $script:Contexts[0]
            $firstContext.Token | Should -BeNullOrEmpty
            $firstContext.TokenAcquiredAt | Should -Be ([datetime]::MinValue)
            $second = Get-FabricCapacityOverageCost -WorkspaceId '99999999-9999-9999-9999-999999999999' -WarningAction SilentlyContinue
            $second.RequestedDays | Should -Be 14
            $second.BasePricePerCUHour | Should -Be ([decimal] '0.18')
            $second.WorkspaceId | Should -Be ([guid] '99999999-9999-9999-9999-999999999999')
            $first.BasePricePerCUHour | Should -Be ([decimal] '0.15')
            Should -Invoke Get-OverageAccessToken -Times 2 -Exactly
            @($script:Contexts | Where-Object { $null -ne $_.Token }).Count | Should -Be 0
            @($script:Requests | Where-Object { $_.Authorization -eq 'Bearer offline-invocation-2' }).Count | Should -BeGreaterThan 0
            @(Get-Variable -Scope Script -Name WorkspaceId, Days, PricePerCU, SemanticModelId, OverageToken, TokenAcquiredAt -ErrorAction SilentlyContinue).Count | Should -Be 0
            $ErrorActionPreference | Should -Be $preference
            $ConfirmPreference | Should -Be $confirm
            $WhatIfPreference | Should -Be $whatIf
        }

        It 'clears state after failure and permits a subsequent invocation' {
            $script:Fixture.truncate = $true
            { Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue } | Should -Throw '*Truncated*'
            $script:Contexts[0].Token | Should -BeNullOrEmpty
            $script:Fixture.truncate = $false
            (Get-FabricCapacityOverageCost -WorkspaceId $script:Fixture.workspaceId -Days 1 -WarningAction SilentlyContinue).Capacities[0].EstimatedCost | Should -Be ([decimal] '0.57')
            Should -Invoke Get-OverageAccessToken -Times 2 -Exactly
        }

    }
}
