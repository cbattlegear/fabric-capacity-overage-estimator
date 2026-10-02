BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
}

InModuleScope FabricCapacityOverage -Parameters @{ FixtureRoot = (Join-Path $PSScriptRoot 'Fixtures') } {
    param($FixtureRoot)
    $script:TestFixtureRoot = $FixtureRoot

    Describe 'Strict fractional refresh freshness' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
            $script:HistoryBody = (Get-Command Get-OverageRefreshHistory).ScriptBlock
        }
        BeforeEach {
            $script:Context = Get-TestContext
            $script:Now = [datetime]::SpecifyKind([datetime] '2026-10-02T18:00:00', [System.DateTimeKind]::Utc)
            $script:History = @([pscustomobject] @{ status = 'Completed'; endTime = $script:Now.AddHours(-1) })
            Mock Get-OverageRefreshHistory { $script:History }
        }

        It 'warns strictly after twelve hours, not at twelve' -TestCases @(
            @{ Age = 11.999; Status = 'Recent'; WarningCount = 0 },
            @{ Age = 12; Status = 'Recent'; WarningCount = 0 },
            @{ Age = 12.000001; Status = 'Stale'; WarningCount = 1 }
        ) {
            param($Age, $Status, $WarningCount)
            $script:History[0].endTime = $script:Now.AddHours(-$Age)
            $warnings = @()
            $freshness = Get-OverageModelFreshness -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -NowUtc $script:Now -WarningVariable warnings -WarningAction SilentlyContinue
            $freshness.Status | Should -Be $Status
            @($warnings).Count | Should -Be $WarningCount
            $freshness.AgeHours | Should -BeGreaterOrEqual 0
        }

        It 'uses the latest successful completion and ignores newer failed/running refreshes' {
            $script:History = @(
                [pscustomobject] @{ status = 'Completed'; endTime = $script:Now.AddHours(-10) },
                [pscustomobject] @{ status = 'Failed'; endTime = $script:Now },
                [pscustomobject] @{ status = 'Unknown'; endTime = $null },
                [pscustomobject] @{ status = 'Completed'; endTime = $script:Now.AddHours(-1) }
            )
            $freshness = Get-OverageModelFreshness -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -NowUtc $script:Now
            $freshness.LastSuccessfulRefreshUtc | Should -Be $script:Now.AddHours(-1)
            $freshness.AgeHours | Should -Be 1
        }

        It 'reports 403 history permission failures as explicit Unknown freshness' {
            Mock Get-OverageRefreshHistory {
                $exception = [System.InvalidOperationException]::new('Offline permission fixture')
                $exception.Data['HttpStatusCode'] = 403
                throw $exception
            }
            $warnings = @()
            $freshness = Get-OverageModelFreshness -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -NowUtc $script:Now -WarningVariable warnings -WarningAction SilentlyContinue
            $freshness.Status | Should -Be 'Unknown'
            $freshness.AgeHours | Should -BeNullOrEmpty
            "$warnings" | Should -Match 'Write permission.*Unknown'
        }

        It 'does not swallow unrelated HTTP <Status> failures' -TestCases @(
            @{ Status = 401 }, @{ Status = 404 }, @{ Status = 500 }, @{ Status = 0 }
        ) {
            param($Status)
            $script:HttpStatus = $Status
            Mock Get-OverageRefreshHistory {
                $exception = [System.InvalidOperationException]::new('Offline nonpermission fixture')
                $exception.Data['HttpStatusCode'] = $script:HttpStatus
                throw $exception
            }
            { Get-OverageModelFreshness -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -NowUtc $script:Now } | Should -Throw '*nonpermission*'
        }

        It 'warns about missing successful history rather than assuming zero age' {
            $script:History = @()
            $warnings = @()
            $freshness = Get-OverageModelFreshness -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -NowUtc $script:Now -WarningVariable warnings -WarningAction SilentlyContinue
            $freshness.Status | Should -Be 'Unknown'
            "$warnings" | Should -Match 'No successful model refresh'
        }

        It 'fails on invalid completed timestamps rather than making freshness Unknown' {
            $script:History[0].endTime = 'invalid'
            { Get-OverageModelFreshness -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -NowUtc $script:Now } | Should -Throw '*Invalid refresh-history*'
        }

        It 'requires a real history entries array: <Label>' -TestCases @(
            @{ Label = 'missing'; Json = '{}' },
            @{ Label = 'null'; Json = '{"value":null}' },
            @{ Label = 'scalar'; Json = '{"value":{"status":"Completed"}}' }
        ) {
            param($Json)
            $script:MalformedHistory = $Json | ConvertFrom-Json
            Mock Invoke-OverageApi { $script:MalformedHistory }
            { & $script:HistoryBody -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' } | Should -Throw '*missing its entries array*'
        }
    }

    Describe 'Opt-in exact-request refresh polling' {
        BeforeAll { . (Join-Path $script:TestFixtureRoot 'Helpers.ps1') }
        BeforeEach {
            $script:Context = Get-TestContext
            $script:RequestId = [guid] '66666666-6666-6666-6666-666666666666'
            $script:PollCount = 0
            $script:Accepted = [pscustomobject] @{
                StatusCode = 202
                Headers = @{ Location = "https://api.powerbi.com/v1.0/myorg/datasets/fixture/refreshes/$script:RequestId" }
            }
            $script:Completed = [pscustomobject] @{
                requestId = $script:RequestId.ToString('D')
                status = 'Completed'
                endTime = '2026-10-02T17:00:00Z'
            }
            Mock Invoke-OverageApi { $script:Accepted }
            Mock Get-OverageRefreshHistory { $script:Completed }
            Mock Start-Sleep {}
        }

        It 'submits once with NoRetry and tracks the accepted request' {
            $result = Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false
            $result.RequestId | Should -Be $script:RequestId
            $result.CompletedAtUtc.Kind | Should -Be ([System.DateTimeKind]::Utc)
            Should -Invoke Invoke-OverageApi -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Post' -and $NoRetry -and $PassThruResponse -and $Body -eq '{"notifyOption":"NoNotification"}'
            }
        }

        It 'does not treat another completed refresh as this request completing' {
            Mock Get-OverageRefreshHistory {
                $script:PollCount++
                if ($script:PollCount -eq 1) {
                    [pscustomobject] @{ requestId = '88888888-8888-8888-8888-888888888888'; status = 'Completed'; endTime = '2026-10-02T17:00:00Z' }
                }
                else { $script:Completed }
            }
            Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false | Out-Null
            Should -Invoke Get-OverageRefreshHistory -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'continues through service running status <Status>' -TestCases @(
            @{ Status = 'Unknown' }, @{ Status = 'InProgress' }, @{ Status = 'NotStarted' }, @{ Status = 'Queued' }
        ) {
            param($Status)
            $script:RunningStatus = $Status
            Mock Get-OverageRefreshHistory {
                $script:PollCount++
                if ($script:PollCount -eq 1) {
                    [pscustomobject] @{ requestId = $script:RequestId.ToString('D'); status = $script:RunningStatus }
                }
                else { $script:Completed }
            }
            (Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false).RequestId | Should -Be $script:RequestId
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'stops on failed/disabled/cancelled refresh status <Status>' -TestCases @(
            @{ Status = 'Failed' }, @{ Status = 'Disabled' }, @{ Status = 'Cancelled' }, @{ Status = 'Canceled' }
        ) {
            param($Status)
            $script:Completed.status = $Status
            { Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false } | Should -Throw "*status '$Status'*No costs were calculated*"
        }

        It 'does not invent success for an unrecognized status' {
            $script:Completed.status = 'Unexpected'
            { Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false } | Should -Throw '*unrecognized status*'
        }

        It 'rejects duplicate entries for the accepted request' {
            Mock Get-OverageRefreshHistory { @($script:Completed, $script:Completed) }
            { Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false } | Should -Throw '*duplicate entries*'
        }

        It 'uses x-ms-request-id when Location is absent' {
            $script:Accepted.Headers = @{ 'x-ms-request-id' = $script:RequestId.ToString('D') }
            (Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false).RequestId | Should -Be $script:RequestId
        }

        It 'rejects untrackable accepted requests without submitting another refresh' {
            $script:Accepted.Headers = @{}
            { Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false } | Should -Throw '*no trackable request ID*no second refresh*'
            Should -Invoke Invoke-OverageApi -Times 1 -Exactly
            Should -Invoke Get-OverageRefreshHistory -Times 0 -Exactly
        }

        It 'rejects unexpected acceptance HTTP status' {
            $script:Accepted.StatusCode = 200
            { Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Confirm:$false } | Should -Throw '*unexpected HTTP 200*'
        }

        It 'times out deterministically without cancelling or returning costs' {
            { Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -TimeoutSeconds 0 -Confirm:$false } | Should -Throw '*Timed out*not cancelled*no costs were calculated*'
            Should -Invoke Invoke-OverageApi -Times 1 -Exactly
            Should -Invoke Get-OverageRefreshHistory -Times 0 -Exactly
        }

        It 'previews with WhatIf without a refresh submission' {
            $result = @(Start-OverageModelRefresh -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -WhatIf)
            $result.Count | Should -Be 0
            Should -Invoke Invoke-OverageApi -Times 0 -Exactly
            Should -Invoke Get-OverageRefreshHistory -Times 0 -Exactly
        }
    }
}
