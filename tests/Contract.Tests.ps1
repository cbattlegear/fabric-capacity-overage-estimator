BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
}

BeforeAll {
    $script:ManifestPath = (Resolve-Path (Join-Path $PSScriptRoot '..\FabricCapacityOverage\FabricCapacityOverage.psd1')).Path
    $script:LauncherPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Get-FabricCapacityOverageCost.ps1')).Path
    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures'
    . (Join-Path $PSScriptRoot 'Fixtures\Helpers.ps1')
    Initialize-TestType -FixtureRoot (Join-Path $PSScriptRoot 'Fixtures')
}

Describe 'Installable module contract' {
    It 'validates its real manifest and required dependency version' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
        $manifest.Name | Should -Be 'FabricCapacityOverage'
        $manifest.Version | Should -Be ([version] '1.0.0')
        $manifest.Guid | Should -Be ([guid] 'bd717c9c-962f-4368-8a03-a6cc2bdbcc7b')
        $manifest.RequiredModules.Count | Should -Be 1
        $manifest.RequiredModules[0].Name | Should -Be 'Az.Accounts'
        $manifest.RequiredModules[0].Version | Should -Be ([version] '5.5.3')
        $manifest.PowerShellVersion | Should -Be ([version] '5.1')
    }

    It 'exports exactly the one public function and no aliases or variables' {
        $module = Get-Module FabricCapacityOverage
        @($module.ExportedFunctions.Keys) | Should -Be @('Get-FabricCapacityOverageCost')
        $module.ExportedCmdlets.Count | Should -Be 0
        $module.ExportedAliases.Count | Should -Be 0
        $module.ExportedVariables.Count | Should -Be 0
        @(Get-Command -Module FabricCapacityOverage).Count | Should -Be 1
        Get-Command Get-OverageAccessToken -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'provides real comment-based help, examples and parameter documentation' {
        $help = Get-Help Get-FabricCapacityOverageCost -Full
        $help.Synopsis | Should -Match 'Estimates additional Fabric'
        @($help.Examples.Example).Count | Should -Be 5
        "$($help.parameters.parameter | Where-Object name -eq 'PricePerCU' | Select-Object -ExpandProperty description)" | Should -Match 'BASE PAYG'
        $help.description.Text | Should -Match 'not an invoice prediction'
    }

    It 'preserves GUID/decimal types, required WorkspaceId and common ShouldProcess parameters' {
        $command = Get-Command Get-FabricCapacityOverageCost
        $command.Parameters.WorkspaceId.ParameterType | Should -Be ([guid])
        @($command.Parameters.WorkspaceId.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 1
        $command.Parameters.PricePerCU.ParameterType | Should -Be ([decimal])
        $command.Parameters.Refresh.ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
        $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $command.Parameters.ContainsKey('Confirm') | Should -BeTrue
        $command.Parameters.WorkspaceId.Aliases | Should -Contain 'CapacityMetricsWorkspaceId'
        $command.Parameters.Days.Aliases | Should -Contain 'NumberOfDays'
        $command.Parameters.PricePerCU.Aliases | Should -Contain 'PaygPricePerCUHour'
    }

    It 'rejects an invalid public parameter before attempting authentication: <Label>' -TestCases @(
        @{ Label = 'empty workspace'; Parameters = @{ WorkspaceId = [guid]::Empty }; Pattern = '*WorkspaceId*' },
        @{ Label = 'malformed workspace'; Parameters = @{ WorkspaceId = 'not-a-guid' }; Pattern = '*WorkspaceId*' },
        @{ Label = 'zero days'; Parameters = @{ WorkspaceId = '11111111-1111-1111-1111-111111111111'; Days = 0 }; Pattern = '*Days*' },
        @{ Label = 'fifteen days'; Parameters = @{ WorkspaceId = '11111111-1111-1111-1111-111111111111'; Days = 15 }; Pattern = '*Days*' },
        @{ Label = 'negative base price'; Parameters = @{ WorkspaceId = '11111111-1111-1111-1111-111111111111'; PricePerCU = -1 }; Pattern = '*PricePerCU*' },
        @{ Label = 'excessive base price'; Parameters = @{ WorkspaceId = '11111111-1111-1111-1111-111111111111'; PricePerCU = 1000001 }; Pattern = '*PricePerCU*' },
        @{ Label = 'empty model'; Parameters = @{ WorkspaceId = '11111111-1111-1111-1111-111111111111'; SemanticModelId = [guid]::Empty }; Pattern = '*SemanticModelId*' }
    ) {
        param($Parameters, $Pattern)
        $arguments = $Parameters
        InModuleScope FabricCapacityOverage -Parameters @{ Arguments = $arguments; Pattern = $Pattern } {
            param($Arguments, $Pattern)
            Mock Get-OverageAccessToken { throw 'Unexpected authentication in validation test.' }
            $callArguments = $Arguments
            { Get-FabricCapacityOverageCost @callArguments } | Should -Throw $Pattern
            Should -Invoke Get-OverageAccessToken -Times 0 -Exactly
        }
    }

    It 'imports in a fresh runspace without authentication, service calls or caller preference changes' {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $pipeline = [powershell]::Create()
        $pipeline.Runspace = $runspace
        try {
            $code = {
                param($ManifestPath)
                $script:ImportCalls = @{ Count = 0 }
                function global:Invoke-RestMethod { $script:ImportCalls.Count++; throw 'Service calls are forbidden at import.' }
                function global:Invoke-WebRequest { $script:ImportCalls.Count++; throw 'Service calls are forbidden at import.' }
                $before = $ErrorActionPreference
                Import-Module $ManifestPath -ErrorAction Stop
                [pscustomobject] @{
                    Calls = $script:ImportCalls.Count
                    SamePreference = $before -eq $ErrorActionPreference
                    Exports = @(Get-Command -Module FabricCapacityOverage).Name
                    HasTokenState = & (Get-Module FabricCapacityOverage) {
                        @(Get-Variable -Scope Script -Name OverageToken, TokenAcquiredAt, WorkspaceId -ErrorAction SilentlyContinue).Count -gt 0
                    }
                }
            }
            $null = $pipeline.AddScript($code.ToString()).AddArgument($script:ManifestPath)
            $result = @($pipeline.Invoke())
            $pipeline.HadErrors | Should -BeFalse
            $result.Count | Should -Be 1
            $result[0].Calls | Should -Be 0
            $result[0].SamePreference | Should -BeTrue
            $result[0].HasTokenState | Should -BeFalse
            @($result[0].Exports) | Should -Be @('Get-FabricCapacityOverageCost')
        }
        finally {
            $pipeline.Dispose()
            $runspace.Dispose()
        }
    }

    It 'uses real declined Confirm without submitting refresh or returning old costs (launcher: <UseLauncher>)' -TestCases @(
        @{ UseLauncher = $false }, @{ UseLauncher = $true }
    ) {
        param($UseLauncher)
        $hostFixture = [FabricCapacityOverage.Tests.ConfirmationHost]::new()
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($hostFixture)
        $runspace.Open()
        $pipeline = [powershell]::Create()
        $pipeline.Runspace = $runspace
        try {
            $code = {
                param($ManifestPath, $LauncherPath, $UseLauncher)
                Import-Module $ManifestPath -ErrorAction Stop
                & (Get-Module FabricCapacityOverage) {
                    $script:ConfirmationRequests = [System.Collections.Generic.List[string]]::new()
                    function script:Invoke-OverageApi {
                        param($Context, $Method, $Path)
                        if ($Context.WorkspaceId -ne [guid] '11111111-1111-1111-1111-111111111111') {
                            throw 'Unexpected workspace in the offline confirmation fixture.'
                        }
                        $script:ConfirmationRequests.Add("$Method $Path")
                        if ($Method -eq 'Get' -and $Path -match '/datasets$') {
                            return [pscustomobject] @{ value = @([pscustomobject] @{
                                id = '22222222-2222-2222-2222-222222222222'
                                name = 'Fabric Capacity Metrics'
                            }) }
                        }
                        throw 'Only offline discovery is allowed in the declined-confirm fixture.'
                    }
                    function script:Get-OverageAccessToken { throw 'Real authentication is forbidden.' }
                }
                $result = @(
                    if ($UseLauncher) {
                        & $LauncherPath -WorkspaceId '11111111-1111-1111-1111-111111111111' -Refresh -Confirm
                    }
                    else {
                        Get-FabricCapacityOverageCost -WorkspaceId '11111111-1111-1111-1111-111111111111' -Refresh -Confirm
                    }
                )
                [pscustomobject] @{
                    ResultCount = @($result).Count
                    Requests = & (Get-Module FabricCapacityOverage) { $script:ConfirmationRequests.ToArray() }
                }
            }
            $null = $pipeline.AddScript($code.ToString()).AddArgument($script:ManifestPath).AddArgument($script:LauncherPath).AddArgument($UseLauncher)
            $result = @($pipeline.Invoke())
            $pipeline.HadErrors | Should -BeFalse
            $hostFixture.PromptCount | Should -Be 1
            $result[0].ResultCount | Should -Be 0
            @($result[0].Requests) | Should -Be @('Get groups/11111111-1111-1111-1111-111111111111/datasets')
        }
        finally {
            $pipeline.Dispose()
            $runspace.Dispose()
        }
    }

    It 'forwards root launcher aliases and common WhatIf through the real bundled module' {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $pipeline = [powershell]::Create()
        $pipeline.Runspace = $runspace
        try {
            $code = {
                param($ManifestPath, $LauncherPath, $FixtureRoot)
                Import-Module $ManifestPath -ErrorAction Stop
                & (Get-Module FabricCapacityOverage) {
                    param($FixtureRoot)
                    . (Join-Path $FixtureRoot 'Helpers.ps1')
                    foreach ($name in @('Invoke-TestApiResponse', 'Get-TestDaxWindow', 'Get-TestDaxResponse')) {
                        Set-Item -Path "Function:script:$name" -Value (Get-Command $name).ScriptBlock
                    }
                    $script:LauncherFixture = Get-Content -LiteralPath (Join-Path $FixtureRoot 'metrics-api.json') -Raw | ConvertFrom-Json
                    $script:LauncherRequests = [System.Collections.Generic.List[object]]::new()
                    function script:Get-OverageUtcNow { ConvertTo-RefreshUtcTime $script:LauncherFixture.nowUtc }
                    function script:Get-OverageAccessToken { throw 'Real authentication is forbidden in the launcher fixture.' }
                    function script:Invoke-OverageApi {
                        param($Context, $Method, $Path, $Body)
                        $Context.Token = 'offline-launcher-token'
                        Invoke-TestApiResponse -Fixture $script:LauncherFixture -Requests $script:LauncherRequests -Uri "https://api.powerbi.com/v1.0/myorg/$Path" -Method $Method -Body $Body -Headers @{ Authorization = "Bearer $($Context.Token)" }
                    }
                } $FixtureRoot
                $result = & $LauncherPath -CapacityMetricsWorkspaceId '11111111-1111-1111-1111-111111111111' -NumberOfDays 1 -PaygPricePerCUHour 0.15 -WarningAction SilentlyContinue
                $count = & (Get-Module FabricCapacityOverage) { $script:LauncherRequests.Count }
                $preview = @(& $LauncherPath -WorkspaceId '11111111-1111-1111-1111-111111111111' -Refresh -WhatIf)
                [pscustomobject] @{
                    Price = $result.OveragePricePerCUHour
                    Days = $result.RequestedDays
                    PreviewCount = $preview.Count
                    AdditionalRequests = (& (Get-Module FabricCapacityOverage) { $script:LauncherRequests.Count }) - $count
                }
            }
            $null = $pipeline.AddScript($code.ToString()).AddArgument($script:ManifestPath).AddArgument($script:LauncherPath).AddArgument($script:FixtureRoot)
            $result = @($pipeline.Invoke())
            $pipeline.HadErrors | Should -BeFalse -Because ($pipeline.Streams.Error -join [Environment]::NewLine)
            $result[0].Price | Should -Be ([decimal] '0.45')
            $result[0].Days | Should -Be 1
            $result[0].PreviewCount | Should -Be 0
            $result[0].AdditionalRequests | Should -Be 1
        }
        finally {
            $pipeline.Dispose()
            $runspace.Dispose()
        }
    }
}
