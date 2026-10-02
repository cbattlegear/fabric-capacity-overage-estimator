BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
}

InModuleScope FabricCapacityOverage -Parameters @{ FixtureRoot = (Join-Path $PSScriptRoot 'Fixtures') } {
    param($FixtureRoot)
    $script:TestFixtureRoot = $FixtureRoot

    Describe 'Decimal same-workload debt replay' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
        }
        BeforeEach {
            $script:Start = [datetime] '2026-10-01T00:00:00'
            $script:Rate = [decimal] '0.54'
        }

        It 'pays current debt once and uses CU-hours with decimal money' {
            $sample = Get-TestSample -Timepoint $script:Start -Carry 7200 -Add 7200 -Delay 1.2
            $result = Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -BeOfType ([decimal])
            $result.EstimatedCUSeconds | Should -Be 7200
            $result.RemainingCarryCUSeconds | Should -Be 0
            $result.PaymentEvents | Should -Be 1
            $result.Daily[0].EstimatedOverageCUHours | Should -Be ([decimal] 2)
            $result.Daily[0].EstimatedCost | Should -Be ([decimal] '1.08')
            $result.DataStatus | Should -Be 'Complete'
        }

        It 'does not pay at exactly 100 percent interactive delay' {
            $sample = Get-TestSample -Timepoint $script:Start -Carry 100 -Add 100 -Delay 1
            $result = Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 0
            $result.RemainingCarryCUSeconds | Should -Be 100
        }

        It 'preserves incoming debt without a warm-up row' {
            $sample = Get-TestSample -Timepoint $script:Start -Carry 7300 -Add 100 -Delay 1.2
            $result = Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.InitialCarryCUSeconds | Should -Be 7200
            $result.EstimatedCUSeconds | Should -Be 7300
        }

        It 'initializes warm-up debt without billing pre-window recorded payments' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 7200 -Billed 200 -Delay 1.2),
                (Get-TestSample -Timepoint $script:Start -Carry 7300 -Add 100 -Delay 1.2)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.InitialCarryCUSeconds | Should -Be 7200
            $result.EstimatedCUSeconds | Should -Be 7200
            $result.RemainingCarryCUSeconds | Should -Be 100
            $result.RecordedCUSeconds | Should -Be 0
            $result.Timepoints | Should -Be 1
        }

        It 'does not double count cumulative snapshots after paying debt' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 7200 -Add 7200 -Delay 1.2),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Carry 7200 -Delay 1.2)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(60) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 7200
            $result.PaymentEvents | Should -Be 1
        }

        It 'does not erase future-smoothed workload demand after payment' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 7200 -Add 7200 -Delay 1.2),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Carry 8000 -Add 800 -Delay 1.1)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(60) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 7200
            $result.RemainingCarryCUSeconds | Should -Be 800
        }

        It 'keeps recorded payments separate instead of clearing hypothetical debt' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 6000 -Delay 0.9),
                (Get-TestSample -Timepoint $script:Start -Billed 6000)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 0
            $result.RecordedCUSeconds | Should -Be 6000
            $result.RemainingCarryCUSeconds | Should -Be 6000
            $result.Daily[0].RecordedCostAtSuppliedPrice | Should -Be ([decimal] '0.90')
        }

        It 'uses the full idle billable budget after recorded burndown was capped by historical debt' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 600 -Delay 0.9),
                (Get-TestSample -Timepoint $script:Start -Billed 600),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Available 480),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60) -Available 480)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(90) -Rate $script:Rate
            $result.RemainingCarryCUSeconds | Should -Be 0
            $result.RecordedCUSeconds | Should -Be 600
            $result.EstimatedCUSeconds | Should -Be 0
        }

        It 'adjusts delay relative to recorded post-payment debt' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 6000 -Delay 0.9),
                (Get-TestSample -Timepoint $script:Start -Billed 6000 -Delay 0.5)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 6000
            $result.RecordedCUSeconds | Should -Be 6000
            $result.PaymentEvents | Should -Be 1
        }

        It 'uses each historical SKU size for the ten-minute allowance' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 1200 -Add 1200 -Delay 0.8),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Billed 1200 -Delay 0.2 -BaseCU 2 -SKU 'F2')
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(60) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 1200
            $result.IneligibleTimepoints | Should -Be 0
        }

        It 'excludes historical non-F timepoints while keeping recorded charges separate' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 7200 -Add 7200 -Delay 2 -SKU 'P1'),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Billed 7200)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(60) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 0
            $result.IneligibleTimepoints | Should -Be 1
            $result.RecordedCUSeconds | Should -Be 7200
        }

        It 'does not turn zero-base-CU timepoints into overage charges' {
            $sample = Get-TestSample -Timepoint $script:Start -Carry 7200 -Delay 2 -BaseCU 0
            $result = Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 0
            $result.RemainingCarryCUSeconds | Should -Be 0
        }

        It 'resets pause/deletion debt but still pays new work at resume/creation' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 7200 -Delay 1.2),
                (Get-TestSample -Timepoint $script:Start -Delay 2),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Carry 6000 -Add 6000 -Delay 1.2)
            )
            $result = Get-OverageReplay -Samples $samples -ResetTimes @($script:Start, $script:Start.AddSeconds(30)) -InactiveTimes @($script:Start) -Start $script:Start -End $script:Start.AddSeconds(60) -Rate $script:Rate
            $result.EstimatedCUSeconds | Should -Be 6000
            $result.PaymentEvents | Should -Be 1
            $result.RecordedCUSeconds | Should -Be 0
        }

        It 'resets debt at a creation/resume boundary even without an inactive row' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 7200 -Delay 0.9),
                (Get-TestSample -Timepoint $script:Start -Carry 100 -Add 100)
            )
            $result = Get-OverageReplay -Samples $samples -ResetTimes @($script:Start) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate $script:Rate
            $result.RemainingCarryCUSeconds | Should -Be 100
            $result.EstimatedCUSeconds | Should -Be 0
        }

        It 'rounds daily currency independently of the aggregate' {
            $end = $script:Start.AddDays(2)
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 34 -Add 34 -Delay 2),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(30) -Billed 34),
                (Get-TestSample -Timepoint $end.AddSeconds(-60) -Carry 34 -Add 34 -Delay 2),
                (Get-TestSample -Timepoint $end.AddSeconds(-30) -Billed 34)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $end -Rate $script:Rate
            ($result.Daily | Measure-Object EstimatedCost -Sum).Sum | Should -Be 0.02
            [math]::Round($result.EstimatedCUSeconds / [decimal] 3600 * $script:Rate, 2) | Should -Be ([decimal] '0.01')
        }
    }

    Describe 'Replay refuses to invent missing costs' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
        }
        BeforeEach { $script:Start = [datetime] '2026-10-01T00:00:00' }

        It 'reports debt-free interior gaps as Partial' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60))
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54
            $result.DataStatus | Should -Be 'Partial'
            $result.MissingTimepoints | Should -Be 1
            $result.Daily[0].ObservedTimepoints | Should -Be 2
            $result.Daily[0].ExpectedTimepoints | Should -Be 3
        }

        It 'does not double count leading gaps after a debt-free warm-up row' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30)),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60))
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54
            $result.MissingTimepoints | Should -Be 2
            $result.Timepoints | Should -Be 1
        }

        It 'uses null rather than zero for a completely unobserved daily bucket' {
            $end = $script:Start.AddDays(3)
            $samples = @(
                (Get-TestSample -Timepoint $script:Start),
                (Get-TestSample -Timepoint $end.AddSeconds(-30))
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $end -Rate 0.54
            $result.Daily[1].ObservedTimepoints | Should -Be 0
            $result.Daily[1].EstimatedCost | Should -BeNullOrEmpty
            $result.Daily[1].RecordedCostAtSuppliedPrice | Should -BeNullOrEmpty
            $result.Daily[1].DataStatus | Should -Be 'Partial'
            $result.MissingTimepoints | Should -Be 8638
        }

        It 'rejects a gap with recorded or simulated outstanding debt' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 100 -Add 100),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60) -Carry 100)
            )
            { Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54 } | Should -Throw '*Missing timepoints while debt is outstanding*'
        }

        It 'does not treat a far-side reset as proof that no payment occurred during a debt-bearing gap' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start -Carry 100 -Add 100),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60))
            )
            { Get-OverageReplay -Samples $samples -ResetTimes @($script:Start.AddSeconds(60)) -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54 } | Should -Throw '*Missing timepoints while debt is outstanding*'
        }

        It 'rejects debt that must have arrived inside an otherwise debt-free gap' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60) -Carry 300 -Add 200)
            )
            { Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54 } | Should -Throw '*Missing timepoints while debt is outstanding*'
        }

        It 'permits new work after a debt-free gap when the ledger shows no incoming debt' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start),
                (Get-TestSample -Timepoint $script:Start.AddSeconds(60) -Carry 200 -Add 200 -Delay 2)
            )
            $result = Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54
            $result.DataStatus | Should -Be 'Partial'
            $result.EstimatedCUSeconds | Should -Be 200
        }

        It 'rejects missing leading timepoints with incoming debt' {
            $sample = Get-TestSample -Timepoint $script:Start.AddSeconds(60) -Carry 100
            { Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(90) -Rate 0.54 } | Should -Throw '*Missing leading timepoints*'
        }

        It 'rejects a trailing gap even if simulated debt was paid but recorded debt remains' {
            $sample = Get-TestSample -Timepoint $script:Start -Carry 7200 -Add 7200 -Delay 1.2
            { Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(60) -Rate 0.54 } | Should -Throw '*Missing trailing timepoints*'
        }

        It 'rejects inconsistent recorded debt ledgers' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 100),
                (Get-TestSample -Timepoint $script:Start -Carry 999)
            )
            { Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*Unexplained carry-forward discontinuity*'
        }

        It 'rejects recorded payments larger than the historical debt instead of clamping the ledger to zero' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 100),
                (Get-TestSample -Timepoint $script:Start -Billed 101)
            )
            { Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*Unexplained carry-forward discontinuity*'
        }

        It 'allows the documented small decimal ledger tolerance' {
            $samples = @(
                (Get-TestSample -Timepoint $script:Start.AddSeconds(-30) -Carry 100),
                (Get-TestSample -Timepoint $script:Start -Carry 100.005)
            )
            (Get-OverageReplay -Samples $samples -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54).RemainingCarryCUSeconds | Should -Be 100
        }

        It 'rejects duplicate timepoints' {
            $sample = Get-TestSample -Timepoint $script:Start
            { Get-OverageReplay -Samples @($sample, $sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*Duplicate or unordered*'
        }

        It 'rejects timepoints at the excluded endpoint' {
            $sample = Get-TestSample -Timepoint $script:Start.AddSeconds(30)
            { Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*Out-of-range*'
        }

        It 'rejects non-30-second and fractional-second timepoints' -TestCases @(
            @{ Seconds = 1 }, @{ Seconds = 0.001 }
        ) {
            param($Seconds)
            $sample = Get-TestSample -Timepoint $script:Start.AddSeconds($Seconds)
            { Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*non-30-second*'
        }

        It 'rejects rows earlier than the single warm-up timepoint' {
            $sample = Get-TestSample -Timepoint $script:Start.AddSeconds(-60)
            { Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*Out-of-range*'
        }

        It 'rejects empty and warm-up-only results' {
            { Get-OverageReplay -Samples @() -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*No joined*'
            $sample = Get-TestSample -Timepoint $script:Start.AddSeconds(-30)
            { Get-OverageReplay -Samples @($sample) -Start $script:Start -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*Only pre-window*'
        }

        It 'rejects empty or unaligned replay windows' {
            { Get-OverageReplay -Samples @() -Start $script:Start -End $script:Start -Rate 0.54 } | Should -Throw '*replay window*'
            { Get-OverageReplay -Samples @() -Start $script:Start.AddSeconds(1) -End $script:Start.AddSeconds(30) -Rate 0.54 } | Should -Throw '*replay window*'
        }
    }
}
