BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:CoreExecutable = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $script:WindowsExecutable = [System.IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System), 'WindowsPowerShell\v1.0\powershell.exe')
    $code = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes('[System.IO.Path]::Combine($PSHOME, "Modules")'))
    $directory = @(& $script:CoreExecutable -NoLogo -NoProfile -NonInteractive -EncodedCommand $code)
    if ($LASTEXITCODE -ne 0 -or $directory.Count -ne 1) { throw 'Could not discover the actual PowerShell 7 native module directory.' }
    $script:CoreNativeModules = $directory[0].Trim()
    $script:WindowsNativeModules = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($script:WindowsExecutable), 'Modules')
    $script:Cache = $env:FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE
    if ([string]::IsNullOrWhiteSpace($script:Cache)) {
        $pester = Get-Module Pester -ErrorAction Stop
        $script:Cache = [System.IO.DirectoryInfo]::new($pester.ModuleBase).Parent.Parent.FullName
    }
    $script:InheritedPath = "$script:CoreNativeModules;$script:Cache;$env:PSModulePath"

    function Invoke-DevelopmentProbe {
        param(
            [string] $Executable, [string] $Mode, [string] $Cache = $script:Cache,
            [string] $InheritedPath = $script:InheritedPath, [string] $RestorePurpose = 'Validation'
        )
        $code = '& ([System.IO.Path]::Combine($env:BOOTSTRAP_TEST_ROOT, "tests\Fixtures\DevelopmentEnvironment.Probe.ps1")) -Mode $env:BOOTSTRAP_TEST_MODE'
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $Executable
        $start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['BOOTSTRAP_TEST_ROOT'] = $script:Root
        $start.EnvironmentVariables['BOOTSTRAP_TEST_MODE'] = $Mode
        $start.EnvironmentVariables['BOOTSTRAP_TEST_RESTORE_PURPOSE'] = $RestorePurpose
        $start.EnvironmentVariables['BOOTSTRAP_TEST_INHERITED_PATH'] = $InheritedPath
        $start.EnvironmentVariables['BOOTSTRAP_TEST_WINDOWS_POWERSHELL'] = $script:WindowsExecutable
        $start.EnvironmentVariables['PSModulePath'] = $InheritedPath
        $start.EnvironmentVariables['GITHUB_ACTIONS'] = 'false'
        $start.EnvironmentVariables['FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE'] = $Cache
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) {
                Stop-Process -Id $process.Id -ErrorAction Stop
                throw 'The fresh-host bootstrap regression timed out.'
            }
            return [pscustomobject] @{
                ExitCode = $process.ExitCode
                Output = $stdout.GetAwaiter().GetResult()
                Error = $stderr.GetAwaiter().GetResult()
            }
        }
        finally { $process.Dispose() }
    }

    function Test-DevelopmentProbeResult {
        param([object] $Result, [string] $Edition)
        $Result.Edition | Should -Be $Edition
        $Result.ModulePath[0] | Should -Be ([System.IO.Path]::Combine($Result.NativeHome, 'Modules'))
        $Result.UtilitySource | Should -Be 'Microsoft.PowerShell.Utility'
        $Result.SecuritySource | Should -Be 'Microsoft.PowerShell.Security'
        $Result.UtilityModuleBase.StartsWith($Result.NativeHome, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $Result.SecurityModuleBase.StartsWith($Result.NativeHome, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $Result.Idempotent | Should -BeTrue
        @($Result.Dependencies).Count | Should -Be 4
        foreach ($name in @('Pester', 'PSScriptAnalyzer', 'Microsoft.PowerShell.PSResourceGet', 'Az.Accounts')) {
            @($Result.Dependencies | Where-Object Name -EQ $name).Count | Should -Be 1
        }
        if ($Edition -eq 'Desktop') { $Result.ModulePath | Should -Not -Contain $script:CoreNativeModules }
    }
}

Describe 'Fresh-process host-native dependency bootstrap' {
    It 'reproduces the original CI native data-import failure with the real PS7 module path in Windows PowerShell' {
        $probe = Invoke-DevelopmentProbe -Executable $script:WindowsExecutable -Mode Broken
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        ($probe.Output | ConvertFrom-Json).MissingDataImport | Should -BeTrue
    }

    It 'restores native Windows PowerShell metadata and all dependencies from the same contaminated CI environment' {
        $probe = Invoke-DevelopmentProbe -Executable $script:WindowsExecutable -Mode Verify
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        $result = $probe.Output | ConvertFrom-Json
        Test-DevelopmentProbeResult -Result $result -Edition Desktop
        $result.ModulePath | Should -Contain $script:Cache
    }

    It 'uses native PowerShell 7 builtins while preserving the isolated cache and removing 5.1 peer builtins' {
        $probe = Invoke-DevelopmentProbe -Executable $script:CoreExecutable -Mode Verify -InheritedPath "$script:WindowsNativeModules;$script:Cache;$script:InheritedPath"
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        $result = $probe.Output | ConvertFrom-Json
        Test-DevelopmentProbeResult -Result $result -Edition Core
        $result.ModulePath | Should -Contain $script:Cache
        $result.ModulePath | Should -Not -Contain $script:WindowsNativeModules
    }

    It 'initializes the actual PS7-to-Windows5.1 signing child without inheriting incompatible native builtins' {
        $probe = Invoke-DevelopmentProbe -Executable $script:CoreExecutable -Mode SigningChild
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        $result = $probe.Output | ConvertFrom-Json
        $result.ParentEdition | Should -Be Core
        $result.ParentModulePath | Should -Match ([regex]::Escape($script:CoreNativeModules))
        Test-DevelopmentProbeResult -Result $result.Child -Edition Desktop
        $result.Child.ModulePath | Should -Contain $script:Cache
    }

    It 'supports local development without GitHub Actions or a dedicated cache variable' {
        $probe = Invoke-DevelopmentProbe -Executable $script:WindowsExecutable -Mode Local
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        Test-DevelopmentProbeResult -Result ($probe.Output | ConvertFrom-Json) -Edition Desktop
    }

    It 'is idempotent with repeated cache and native directory prefixes' {
        $path = "$script:Cache;$script:Cache\;$script:WindowsNativeModules;$script:WindowsNativeModules;$script:InheritedPath"
        $probe = Invoke-DevelopmentProbe -Executable $script:WindowsExecutable -Mode Verify -InheritedPath $path
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        $result = $probe.Output | ConvertFrom-Json
        Test-DevelopmentProbeResult -Result $result -Edition Desktop
        @($result.ModulePath | Where-Object { $_ -eq $script:Cache }).Count | Should -Be 1
        @($result.ModulePath | Where-Object { $_ -eq $script:WindowsNativeModules }).Count | Should -Be 1
    }

    It 'constructs appropriate native scopes when an inherited module path is empty' {
        $probe = Invoke-DevelopmentProbe -Executable $script:WindowsExecutable -Mode EmptyPath
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        Test-DevelopmentProbeResult -Result ($probe.Output | ConvertFrom-Json) -Edition Desktop
    }

    It 'fails explicitly for a configured missing cache rather than falling back to normal installations' {
        $probe = Invoke-DevelopmentProbe -Executable $script:WindowsExecutable -Mode Verify -Cache (Join-Path $TestDrive 'missing-cache')
        $probe.ExitCode | Should -Be 1
        $probe.Error | Should -Match 'FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE.*existing absolute'
    }
}

Describe 'All validation and manual release entrypoints use the native bootstrap' {
    It 'restores only a cache location in GITHUB_ENV, never a host-specific PSModulePath' {
        $restore = Get-Content -LiteralPath (Join-Path $script:Root 'scripts\Restore-DevelopmentDependencies.ps1') -Raw
        $restore | Should -Match 'AppendAllText\(\$env:GITHUB_ENV, "FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE=\$cache'
        $restore | Should -Not -Match 'AppendAllText\(\$env:GITHUB_ENV, "PSModulePath='
        $bootstrap = Get-Content -LiteralPath (Join-Path $script:Root 'scripts\Initialize-DevelopmentEnvironment.ps1') -Raw
        $bootstrap | Should -Not -Match 'Save-PSResource|Install-Module|Set-ExecutionPolicy|GITHUB_ENV'
    }

    It 'bootstraps before native metadata/import/helper operations in <Script>' -TestCases @(
        @{ Script = 'Test-Module.ps1' }, @{ Script = 'Build-Package.ps1' }, @{ Script = 'Test-Package.ps1' },
        @{ Script = 'Restore-DevelopmentDependencies.ps1' }, @{ Script = 'Stage-Release.ps1' },
        @{ Script = 'Complete-SigningRelease.ps1' }, @{ Script = 'Receive-SigningRelease.ps1' },
        @{ Script = 'Publish-SigningRelease.ps1' }, @{ Script = 'Test-SigningConfiguration.ps1' },
        @{ Script = 'Release\Release.Helpers.ps1' }
    ) {
        param($Script)
        $path = Join-Path $script:Root "scripts\$Script"
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $ast.EndBlock.Statements[0].Extent.Text | Should -Match '^& \(\[System.IO.Path\]::Combine\(\$PSScriptRoot, ''(?:\.\.\\)?Initialize-DevelopmentEnvironment.ps1''\)\)$'
    }

    It 'initializes each workflow host before evaluating path expressions, including the explicit signing child' {
        $validate = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\validate.yml') -Raw
        ([regex]::Matches($validate, '\.\\scripts\\Initialize-DevelopmentEnvironment.ps1')).Count | Should -Be 3
        $sign = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\sign-module.yml') -Raw
        $sign | Should -Match 'powershell.exe.*-Command.*Initialize-DevelopmentEnvironment.ps1; \.\\scripts\\Test-Module.ps1'
    }
}

Describe 'Runner restoration exports only the isolated cache directory' {
    It 'shares only the cache path while validation/publishing restore remains explicit: <Purpose>' -TestCases @(
        @{ Purpose = 'Validation' },
        @{ Purpose = 'Publishing' }
    ) {
        param($Purpose)
        $probe = Invoke-DevelopmentProbe -Executable $script:CoreExecutable -Mode Restore -RestorePurpose $Purpose
        $probe.ExitCode | Should -Be 0 -Because $probe.Error
        $result = $probe.Output | ConvertFrom-Json
        $result.PassedCount | Should -Be 1
        $result.Purpose | Should -Be $Purpose
    }
}
