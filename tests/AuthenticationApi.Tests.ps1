BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
}

InModuleScope FabricCapacityOverage -Parameters @{ FixtureRoot = (Join-Path $PSScriptRoot 'Fixtures') } {
    param($FixtureRoot)
    $script:TestFixtureRoot = $FixtureRoot

    Describe 'Offline token acquisition' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
            $script:NativeCliBody = (Get-Command Invoke-OverageCliToken).ScriptBlock
        }
        BeforeEach {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-OverageCliToken { throw 'Unexpected real CLI token request.' }
            Mock Get-AzContext { [pscustomobject] @{ Account = 'offline-account' } }
            Mock Get-AzAccessToken { [pscustomobject] @{ Token = 'offline-az-token' } }
        }

        It 'uses Azure CLI first when available and authenticated' {
            Mock Get-Command { [pscustomobject] @{ Source = 'offline-cli' } } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-OverageCliToken { 'offline-cli-token' }
            Get-OverageAccessToken | Should -Be 'offline-cli-token'
            Should -Invoke Get-AzAccessToken -Times 0 -Exactly
            Should -Invoke Invoke-OverageCliToken -Times 1 -Exactly -ParameterFilter { $CommandPath -eq 'offline-cli' }
        }

        It 'falls back to Az.Accounts after unavailable CLI authentication' {
            Mock Get-Command { [pscustomobject] @{ Source = 'offline-cli' } } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-OverageCliToken { throw 'native-sensitive-fixture-that-must-not-leak' }
            Get-OverageAccessToken | Should -Be 'offline-az-token'
            Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter {
                $ResourceUrl -eq 'https://analysis.windows.net/powerbi/api'
            }
        }

        It 'accepts legacy string token output' {
            Get-OverageAccessToken | Should -Be 'offline-az-token'
        }

        It 'unwraps current SecureString token output' {
            $script:SecureFixture = [System.Security.SecureString]::new()
            foreach ($character in 'offline-secure-token'.ToCharArray()) { $script:SecureFixture.AppendChar($character) }
            $script:SecureFixture.MakeReadOnly()
            try {
                Mock Get-AzAccessToken { [pscustomobject] @{ Token = $script:SecureFixture } }
                Get-OverageAccessToken | Should -Be 'offline-secure-token'
                $script:SecureFixture.IsReadOnly() | Should -BeTrue
            }
            finally { $script:SecureFixture.Dispose() }
        }

        It 'requires an authenticated Az context instead of logging in automatically' {
            Mock Get-AzContext { $null }
            { Get-OverageAccessToken } | Should -Throw '*Connect-AzAccount*'
            Should -Invoke Get-AzAccessToken -Times 0 -Exactly
        }

        It 'rejects an empty Az token' {
            Mock Get-AzAccessToken { [pscustomobject] @{ Token = '' } }
            { Get-OverageAccessToken } | Should -Throw '*Az.Accounts authentication failed*'
        }

        It 'does not echo token/native failures in combined authentication errors' {
            Mock Get-Command { [pscustomobject] @{ Source = 'offline-cli' } } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-OverageCliToken { throw 'native-sensitive-fixture-that-must-not-leak' }
            Mock Get-AzAccessToken { throw 'az-sensitive-fixture-that-must-not-leak' }
            $message = try { Get-OverageAccessToken } catch { $_.Exception.Message }
            $message | Should -Match 'Azure CLI authentication failed'
            $message | Should -Match 'Connect-AzAccount'
            $message | Should -Not -Match 'sensitive-fixture'
        }

        It 'executes only the deterministic native CLI fixture with the expected arguments' {
            $token = & $script:NativeCliBody -CommandPath (Join-Path $script:TestFixtureRoot 'CliSuccess.cmd')
            $token | Should -Be 'offline-cli-token'
        }

        It 'checks native exit status without leaking stderr or caller preferences' {
            $preference = $ErrorActionPreference
            $message = try { & $script:NativeCliBody -CommandPath (Join-Path $script:TestFixtureRoot 'CliFailure.cmd') } catch { $_.Exception.Message }
            $message | Should -Match 'Azure CLI could not acquire'
            $message | Should -Not -Match 'offline-native-error'
            $ErrorActionPreference | Should -Be $preference
        }
    }

    Describe 'Authenticated REST retries without live requests' {
        BeforeAll {
            . (Join-Path $script:TestFixtureRoot 'Helpers.ps1')
            Initialize-TestType -FixtureRoot $script:TestFixtureRoot
        }
        BeforeEach {
            $script:Context = Get-TestContext
            $script:Now = [datetime]::SpecifyKind([datetime] '2026-10-02T18:00:00', [System.DateTimeKind]::Utc)
            $script:TokenCalls = 0
            $script:Attempts = 0
            Mock Get-OverageUtcNow { $script:Now }
            Mock Get-OverageAccessToken { $script:TokenCalls++; "offline-token-$script:TokenCalls" }
            Mock Start-Sleep {}
            Mock Invoke-RestMethod { [pscustomobject] @{ value = 'offline-success' } }
            Mock Invoke-WebRequest { throw 'Unexpected live web request.' }
        }

        It 'reuses a token only inside the supplied invocation context' {
            Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets' | Out-Null
            Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets' | Out-Null
            Should -Invoke Get-OverageAccessToken -Times 1 -Exactly
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
                $Headers.Authorization -eq 'Bearer offline-token-1' -and $TimeoutSec -eq 180
            }
        }

        It 'refreshes tokens strictly after forty minutes' -TestCases @(
            @{ Minutes = 40; ExpectedCalls = 0 }, @{ Minutes = 40.01; ExpectedCalls = 1 }
        ) {
            param($Minutes, $ExpectedCalls)
            $script:Context.Token = 'offline-previous-token'
            $script:Context.TokenAcquiredAt = $script:Now.AddMinutes(-$Minutes)
            Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets' | Out-Null
            Should -Invoke Get-OverageAccessToken -Times $ExpectedCalls -Exactly
        }

        It 'reacquires once after a rejected 401' {
            Mock Invoke-RestMethod {
                $script:Attempts++
                if ($script:Attempts -eq 1) { throw [FabricCapacityOverage.Tests.HttpException]::new(401, $null) }
                [pscustomobject] @{ value = 'offline-success' }
            }
            (Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets').value | Should -Be 'offline-success'
            Should -Invoke Get-OverageAccessToken -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'does not repeatedly retry unauthorized requests' {
            Mock Invoke-RestMethod { throw [FabricCapacityOverage.Tests.HttpException]::new(401, $null) }
            { Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets' } | Should -Throw '*HTTP 401*Read/Build*'
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
            Should -Invoke Get-OverageAccessToken -Times 2 -Exactly
        }

        It 'retries bounded transient status <Status>' -TestCases @(
            @{ Status = 429 }, @{ Status = 502 }, @{ Status = 503 }, @{ Status = 504 }
        ) {
            param($Status)
            $script:HttpStatus = $Status
            Mock Invoke-RestMethod { throw [FabricCapacityOverage.Tests.HttpException]::new($script:HttpStatus, $null) }
            { Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets' } | Should -Throw "*HTTP $Status*"
            Should -Invoke Invoke-RestMethod -Times 6 -Exactly
            Should -Invoke Start-Sleep -Times 5 -Exactly
        }

        It 'honors integer Retry-After headers without sleeping in tests' {
            $script:RetryHeaders = [System.Net.WebHeaderCollection]::new()
            $script:RetryHeaders['Retry-After'] = '20'
            Mock Invoke-RestMethod {
                $script:Attempts++
                if ($script:Attempts -eq 1) { throw [FabricCapacityOverage.Tests.HttpException]::new(429, $script:RetryHeaders) }
                [pscustomobject] @{ value = 'offline-success' }
            }
            Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets' | Out-Null
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 20 }
        }

        It 'honors date and typed Retry-After headers' {
            $headers = [System.Net.WebHeaderCollection]::new()
            $headers['Retry-After'] = $script:Now.AddSeconds(25).ToString('r')
            Get-OverageRetryDelay -Response ([pscustomobject] @{ Headers = $headers }) -Attempt 0 | Should -Be 25
            $typedHeaders = [pscustomobject] @{ RetryAfter = [pscustomobject] @{ Delta = [timespan]::FromSeconds(15.1); Date = $null } }
            Get-OverageRetryDelay -Response ([pscustomobject] @{ Headers = $typedHeaders }) -Attempt 0 | Should -Be 16
            $dateHeaders = [pscustomobject] @{ RetryAfter = [pscustomobject] @{ Delta = $null; Date = [datetimeoffset] $script:Now.AddSeconds(30) } }
            Get-OverageRetryDelay -Response ([pscustomobject] @{ Headers = $dateHeaders }) -Attempt 0 | Should -Be 30
        }

        It 'does not swallow nontransient permission failures' {
            Mock Invoke-RestMethod { throw [FabricCapacityOverage.Tests.HttpException]::new(403, $null) }
            $errorRecord = try { Invoke-OverageApi -Context $script:Context -Method Get -Path 'groups/fixture/datasets'; $null } catch { $_ }
            $errorRecord.Exception.Data['HttpStatusCode'] | Should -Be 403
            $errorRecord.Exception.Message | Should -Match 'HTTP 403'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }

        It 'never retries an ambiguous refresh submission with HTTP <Status>' -TestCases @(
            @{ Status = 429 }, @{ Status = 503 }, @{ Status = 504 }
        ) {
            param($Status)
            $script:HttpStatus = $Status
            Mock Invoke-WebRequest { throw [FabricCapacityOverage.Tests.HttpException]::new($script:HttpStatus, $null) }
            { Invoke-OverageApi -Context $script:Context -Method Post -Path 'groups/fixture/datasets/fixture/refreshes' -Body '{}' -PassThruResponse -NoRetry } | Should -Throw '*not automatically retried*already have accepted*'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'never retries refresh submission after a transport failure' {
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('Offline transport failure') }
            { Invoke-OverageApi -Context $script:Context -Method Post -Path 'groups/fixture/datasets/fixture/refreshes' -Body '{}' -PassThruResponse -NoRetry } | Should -Throw '*HTTP 0*not automatically retried*'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'permits exactly one new-token retry for a rejected refresh 401' {
            Mock Invoke-WebRequest {
                $script:Attempts++
                if ($script:Attempts -eq 1) { throw [FabricCapacityOverage.Tests.HttpException]::new(401, $null) }
                [pscustomobject] @{ StatusCode = 202; Headers = @{} }
            }
            (Invoke-OverageApi -Context $script:Context -Method Post -Path 'groups/fixture/datasets/fixture/refreshes' -Body '{}' -PassThruResponse -NoRetry).StatusCode | Should -Be 202
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    Describe 'Execute Queries response validation' {
        BeforeAll { . (Join-Path $script:TestFixtureRoot 'Helpers.ps1') }
        BeforeEach {
            $script:Context = Get-TestContext
            $script:DaxResponse = Get-TestDaxResponse -Rows @([pscustomobject] @{ '[fixture]' = 1 })
            Mock Invoke-OverageApi { $script:DaxResponse }
        }

        It 'serializes exactly one query and requests null metrics explicitly' {
            $rows = @(Invoke-OverageDax -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Query 'EVALUATE ROW("fixture", 1)')
            $rows.Count | Should -Be 1
            Should -Invoke Invoke-OverageApi -Times 1 -Exactly -ParameterFilter {
                $decoded = $Body | ConvertFrom-Json
                $decoded.queries.Count -eq 1 -and $decoded.serializerSettings.includeNulls -eq $true -and
                $Path -eq 'datasets/22222222-2222-2222-2222-222222222222/executeQueries'
            }
        }

        It 'accepts a genuine empty rows array as missing coverage, not an API failure' {
            $script:DaxResponse = Get-TestDaxResponse
            @(Invoke-OverageDax -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Query 'fixture').Count | Should -Be 0
        }

        It 'rejects an invalid or truncated DAX envelope: <Label>' -TestCases @(
            @{ Label = 'top-level error'; Json = '{"error":{"code":"fixture"}}'; Pattern = '*DAX response error*' },
            @{ Label = 'query error'; Json = '{"results":[{"error":{"code":"fixture"}}]}'; Pattern = '*DAX query error*' },
            @{ Label = 'table error'; Json = '{"results":[{"tables":[{"error":{"code":"fixture"}}]}]}'; Pattern = '*DAX table error*' },
            @{ Label = 'missing results'; Json = '{}'; Pattern = '*exactly one query result*' },
            @{ Label = 'multiple results'; Json = '{"results":[{},{}]}'; Pattern = '*exactly one query result*' },
            @{ Label = 'missing table'; Json = '{"results":[{}]}'; Pattern = '*exactly one result table*' },
            @{ Label = 'multiple tables'; Json = '{"results":[{"tables":[{},{}]}]}'; Pattern = '*exactly one result table*' },
            @{ Label = 'missing rows'; Json = '{"results":[{"tables":[{}]}]}'; Pattern = '*no rows array*' },
            @{ Label = 'null rows'; Json = '{"results":[{"tables":[{"rows":null}]}]}'; Pattern = '*no rows array*' },
            @{ Label = 'scalar rows'; Json = '{"results":[{"tables":[{"rows":{"fixture":1}}]}]}'; Pattern = '*no rows array*' }
        ) {
            param($Json, $Pattern)
            $script:DaxResponse = $Json | ConvertFrom-Json
            { Invoke-OverageDax -Context $script:Context -ModelId '22222222-2222-2222-2222-222222222222' -Query 'fixture' } | Should -Throw $Pattern
        }
    }
}
