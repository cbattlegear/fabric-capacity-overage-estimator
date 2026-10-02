BeforeAll {
    $script:Root = $Root
    $script:Purpose = $Purpose
}

Describe 'Restoration in its required PowerShell 7 runner host without network calls' {
    BeforeEach {
        $script:SavedEnvironment = @{}
        foreach ($name in @('GITHUB_ACTIONS', 'RUNNER_TEMP', 'GITHUB_ENV', 'FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE', 'PSModulePath')) {
            $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:GITHUB_ACTIONS = 'true'
        $env:RUNNER_TEMP = Join-Path $TestDrive 'runner'
        $null = New-Item -ItemType Directory -Path $env:RUNNER_TEMP
        $env:GITHUB_ENV = Join-Path $env:RUNNER_TEMP 'github-env'
        Mock Save-PSResource {}
    }
    AfterEach {
        foreach ($name in $script:SavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name], 'Process')
        }
    }

    It 'exports exactly the cache location, with explicit purpose-specific restore calls' {
        & (Join-Path $script:Root 'scripts\Restore-DevelopmentDependencies.ps1') -Purpose $script:Purpose
        $expected = Join-Path $env:RUNNER_TEMP 'overage-development-modules'
        (Get-Content -LiteralPath $env:GITHUB_ENV -Raw) | Should -Be "FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE=$expected`n"
        $env:FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE | Should -Be $expected
        $env:PSModulePath -split ';' | Should -Contain $expected
        $count = if ($script:Purpose -eq 'Validation') { 4 } else { 1 }
        Should -Invoke Save-PSResource -Times $count -Exactly
    }
}
