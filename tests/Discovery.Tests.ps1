BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
}

InModuleScope FabricCapacityOverage -Parameters @{ FixtureRoot = (Join-Path $PSScriptRoot 'Fixtures') } {
    param($FixtureRoot)
    $script:TestFixtureRoot = $FixtureRoot

    Describe 'Model timestamps and numeric metrics' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
        }

        It 'preserves the app clock from an ISO timestamp string' {
            $time = ConvertTo-ModelTime '2026-10-01T15:45:30'
            $time.ToString('s') | Should -Be '2026-10-01T15:45:30'
            $time.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
        }

        It 'does not shift a typed DateTime with <Kind> kind' -TestCases @(
            @{ Kind = 'Utc' }, @{ Kind = 'Local' }, @{ Kind = 'Unspecified' }
        ) {
            param($Kind)
            $value = [datetime]::SpecifyKind([datetime] '2026-10-01T15:45:30', [System.DateTimeKind] $Kind)
            $time = ConvertTo-ModelTime $value
            $time.Ticks | Should -Be $value.Ticks
            $time.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
        }

        It 'preserves typed DateTimeOffset wall time at offset <Offset>' -TestCases @(
            @{ Offset = -7 }, @{ Offset = 5.5 }, @{ Offset = 0 }
        ) {
            param($Offset)
            $value = [datetimeoffset]::new(2026, 10, 1, 15, 45, 30, [timespan]::FromHours($Offset))
            $time = ConvertTo-ModelTime $value
            $time.ToString('s') | Should -Be '2026-10-01T15:45:30'
            $time.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
        }

        It 'rejects an invalid model timestamp: <Label>' -TestCases @(
            @{ Label = 'null'; Value = $null }, @{ Label = 'empty'; Value = '' },
            @{ Label = 'locale-dependent'; Value = '10/01/2026 15:45:30' },
            @{ Label = 'timezone-decorated string'; Value = '2026-10-01T15:45:30Z' },
            @{ Label = 'impossible date'; Value = '2026-02-30T15:45:30' }
        ) {
            param($Value)
            $inputValue = $Value
            { ConvertTo-ModelTime $inputValue } | Should -Throw '*Invalid model timestamp*'
        }

        It 'uses UTC rather than wall time for refresh history' {
            (ConvertTo-RefreshUtcTime '2026-10-01T15:45:30+05:30').ToString('o') | Should -Be '2026-10-01T10:15:30.0000000Z'
            $offset = [datetimeoffset]::new(2026, 10, 1, 15, 45, 30, [timespan]::FromHours(-7))
            (ConvertTo-RefreshUtcTime $offset).Hour | Should -Be 22
        }

        It 'interprets an unspecified refresh DateTime as UTC' {
            $value = [datetime]::SpecifyKind([datetime] '2026-10-01T15:45:30', [System.DateTimeKind]::Unspecified)
            $time = ConvertTo-RefreshUtcTime $value
            $time.Ticks | Should -Be $value.Ticks
            $time.Kind | Should -Be ([System.DateTimeKind]::Utc)
        }

        It 'converts a local refresh DateTime to UTC' {
            $value = [datetime]::SpecifyKind([datetime] '2026-10-01T15:45:30', [System.DateTimeKind]::Local)
            (ConvertTo-RefreshUtcTime $value) | Should -Be $value.ToUniversalTime()
        }

        It 'rejects malformed refresh-history timestamps' {
            { ConvertTo-RefreshUtcTime 'yesterday' } | Should -Throw '*Invalid refresh-history UTC timestamp*'
            { ConvertTo-RefreshUtcTime $null } | Should -Throw '*Invalid refresh-history UTC timestamp*'
        }

        It 'parses metrics invariantly and retains decimal precision' {
            $culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                $number = ConvertTo-MetricNumber '1234.1234567890123456789' 'fixture'
                $number | Should -BeOfType ([decimal])
                $expected = [decimal]::Parse('1234.1234567890123456789', [System.Globalization.CultureInfo]::InvariantCulture)
                $number | Should -Be $expected
                (ConvertTo-ModelTime '2026-10-01T15:45:30').Hour | Should -Be 15
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture }
        }

        It 'accepts zero and scientific notation as real metrics' {
            (ConvertTo-MetricNumber 0 'zero') | Should -Be ([decimal] 0)
            (ConvertTo-MetricNumber '1.25E2' 'scientific') | Should -Be ([decimal] 125)
        }

        It 'rejects invalid metrics rather than turning them into zero: <Label>' -TestCases @(
            @{ Label = 'null'; Value = $null }, @{ Label = 'empty'; Value = '' },
            @{ Label = 'negative'; Value = -1 }, @{ Label = 'NaN'; Value = [double]::NaN },
            @{ Label = 'infinity'; Value = [double]::PositiveInfinity },
            @{ Label = 'locale decimal'; Value = '1,25' },
            @{ Label = 'overflow'; Value = '1E100' }
        ) {
            param($Value)
            $inputValue = $Value
            { ConvertTo-MetricNumber $inputValue 'fixture' } | Should -Throw '*Invalid or missing nonnegative numeric metric*'
        }

        It 'reads both bracketed and unbracketed field names without dropping zero' {
            Get-QueryField ([pscustomobject] @{ '[fixture]' = 0 }) 'fixture' | Should -Be 0
            Get-QueryField ([pscustomobject] @{ fixture = 123 }) 'fixture' | Should -Be 123
            { Get-QueryField ([pscustomobject] @{}) 'fixture' } | Should -Throw "*missing 'fixture'*"
        }

        It 'preserves enumerable HTTP metadata and empty arrays' {
            $headers = [System.Net.WebHeaderCollection]::new()
            $headers['Retry-After'] = '20'
            $value = Get-OptionalProperty ([pscustomobject] @{ Headers = $headers }) 'Headers'
            $value.GetType() | Should -Be ([System.Net.WebHeaderCollection])
            @(Get-OptionalProperty ([pscustomobject] @{ value = @() }) 'value').Count | Should -Be 0
        }
    }

    Describe 'Semantic model discovery and DirectQuery series' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
            $script:TestModels = @(
                [pscustomobject] @{ id = '22222222-2222-2222-2222-222222222222'; name = 'Fabric Capacity Metrics' },
                [pscustomobject] @{ id = '77777777-7777-7777-7777-777777777777'; name = 'Unrelated model' }
            )
        }

        It 'selects only the single Metrics App model among unrelated models' {
            (Get-OverageModel -Models $script:TestModels -RequestedId ([guid]::Empty)).id | Should -Be $script:TestModels[0].id
        }

        It 'accepts a single renamed app model' {
            $model = [pscustomobject] @{ id = $script:TestModels[0].id; name = 'Renamed model' }
            (Get-OverageModel -Models @($model) -RequestedId ([guid]::Empty)).name | Should -Be 'Renamed model'
        }

        It 'selects an explicit model only if it belongs to the workspace' {
            (Get-OverageModel -Models $script:TestModels -RequestedId $script:TestModels[1].id).id | Should -Be $script:TestModels[1].id
            { Get-OverageModel -Models $script:TestModels -RequestedId '99999999-9999-9999-9999-999999999999' } | Should -Throw '*not accessible in workspace*'
        }

        It 'rejects multiple Metrics App candidates' {
            $second = [pscustomobject] @{ id = $script:TestModels[1].id; name = 'Premium Capacity Metrics' }
            { Get-OverageModel -Models @($script:TestModels[0], $second) -RequestedId ([guid]::Empty) } | Should -Throw '*unambiguously*SemanticModelId*'
        }

        It 'rejects multiple unrelated models instead of guessing' {
            $first = [pscustomobject] @{ id = $script:TestModels[0].id; name = 'One' }
            $second = [pscustomobject] @{ id = $script:TestModels[1].id; name = 'Two' }
            { Get-OverageModel -Models @($first, $second) -RequestedId ([guid]::Empty) } | Should -Throw '*unambiguously*'
        }

        It 'rejects duplicate explicit model IDs' {
            { Get-OverageModel -Models @($script:TestModels[0], $script:TestModels[0]) -RequestedId $script:TestModels[0].id } | Should -Throw '*not accessible*'
        }

        It 'scopes DirectQuery using an uppercase GUID and exclusive boundary' {
            $query = Get-OverageSeriesQuery -CapacityId 'aabbccdd-0011-2233-4455-66778899aabb' -Start '2026-10-01T00:00:00' -End '2026-10-02T00:00:00'
            $query | Should -Match "MPARAMETER 'CapacitiesList' = \{ ""AABBCCDD-0011-2233-4455-66778899AABB"" \}"
            $query | Should -Match 'Window start time\] < \(DATE\(2026,10,2\)'
            $query | Should -Match 'ExpectedRowCount = COUNTROWS\(Series\)'
            $query | Should -Match 'NATURALLEFTOUTERJOIN\(UsageRows, DebtRows\)'
            $query | Should -Match 'FORMAT'
            $query | Should -Not -Match 'Nonbillable'
        }

        It 'converts billable usage to the full idle burndown budget' {
            $fixture = Get-Content -LiteralPath (Join-Path $script:TestFixtureRoot 'metrics-api.json') -Raw | ConvertFrom-Json
            $row = $fixture.series[0]
            $row.'[BillableInteractiveCUSeconds]' = 120
            $row.'[BillableBackgroundCUSeconds]' = 240
            $row | Add-Member -NotePropertyName '[NonbillableCUSeconds]' -NotePropertyValue 1000000
            $row | Add-Member -NotePropertyName '[ExpectedRows]' -NotePropertyValue 1
            $series = @(ConvertTo-OverageSeries -Rows @($row))
            $series[0].AvailableBurndown | Should -Be ([decimal] 120)
            $series[0].RecordedCarry | Should -BeOfType ([decimal])
        }

        It 'never makes idle burndown negative' {
            $fixture = Get-Content -LiteralPath (Join-Path $script:TestFixtureRoot 'metrics-api.json') -Raw | ConvertFrom-Json
            $row = $fixture.series[0]
            $row.'[BillableInteractiveCUSeconds]' = 1000
            $row | Add-Member -NotePropertyName '[ExpectedRows]' -NotePropertyValue 1
            (ConvertTo-OverageSeries -Rows @($row)).AvailableBurndown | Should -Be 0
        }

        It 'rejects incomplete joined metric <Field>' -TestCases @(
            @{ Field = 'RecordedCarryCUSeconds' }, @{ Field = 'AddCUSeconds' }, @{ Field = 'BurndownCUSeconds' },
            @{ Field = 'BaseCU' }, @{ Field = 'DelayRatio' }, @{ Field = 'RecordedBilledCUSeconds' },
            @{ Field = 'BillableInteractiveCUSeconds' }, @{ Field = 'BillableBackgroundCUSeconds' }
        ) {
            param($Field)
            $fixture = Get-Content -LiteralPath (Join-Path $script:TestFixtureRoot 'metrics-api.json') -Raw | ConvertFrom-Json
            $row = $fixture.series[0]
            $row.PSObject.Properties["[$Field]"].Value = $null
            $row | Add-Member -NotePropertyName '[ExpectedRows]' -NotePropertyValue 1
            { ConvertTo-OverageSeries -Rows @($row) } | Should -Throw '*Invalid or missing*'
        }

        It 'rejects an expected-row-count mismatch' {
            $fixture = Get-Content -LiteralPath (Join-Path $script:TestFixtureRoot 'metrics-api.json') -Raw | ConvertFrom-Json
            $row = $fixture.series[0]
            $row | Add-Member -NotePropertyName '[ExpectedRows]' -NotePropertyValue 2
            { ConvertTo-OverageSeries -Rows @($row) } | Should -Throw '*Truncated DAX response*expected 2*received 1*'
        }
    }
}
