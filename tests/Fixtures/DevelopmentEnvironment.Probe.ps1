#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Broken', 'Verify', 'SigningChild', 'Local', 'EmptyPath', 'Restore')] [string] $Mode)

$ErrorActionPreference = 'Stop'
try {
    # The runner/PS7-parent path is deliberately inherited as data, not sanitized
    # by this fixture before the real repository bootstrap executes.
    $env:PSModulePath = $env:BOOTSTRAP_TEST_INHERITED_PATH
    $bootstrap = [System.IO.Path]::Combine($env:BOOTSTRAP_TEST_ROOT, 'scripts\Initialize-DevelopmentEnvironment.ps1')
    if ($Mode -eq 'Broken') {
        $missing = $null -eq (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue)
        [Console]::Out.WriteLine('{"MissingDataImport":' + $missing.ToString().ToLowerInvariant() + '}')
        exit 0
    }
    if ($Mode -eq 'Local') { $env:FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE = $null }
    if ($Mode -eq 'EmptyPath') { $env:PSModulePath = '' }
    & $bootstrap

    if ($Mode -eq 'Restore') {
        Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = @()
        $configuration.Run.Container = @(New-PesterContainer -Path ([System.IO.Path]::Combine(
            $env:BOOTSTRAP_TEST_ROOT, 'tests\Fixtures\RestoreDependencies.Probe.Tests.ps1'
        )) -Data @{ Root = $env:BOOTSTRAP_TEST_ROOT; Purpose = $env:BOOTSTRAP_TEST_RESTORE_PURPOSE })
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'None'
        $result = Invoke-Pester -Configuration $configuration
        if ($result.FailedCount -gt 0 -or $result.PassedCount -ne 1) { throw 'The mocked runner-only restoration regression failed.' }
        [pscustomobject] @{ PassedCount = $result.PassedCount; Purpose = $env:BOOTSTRAP_TEST_RESTORE_PURPOSE } |
            ConvertTo-Json -Compress
        exit 0
    }

    if ($Mode -eq 'SigningChild') {
        if ($PSVersionTable.PSEdition -ne 'Core') { throw 'The signing-parent regression must run in PowerShell 7.' }
        $env:BOOTSTRAP_TEST_INHERITED_PATH = $env:PSModulePath
        $code = '& ([System.IO.Path]::Combine($env:BOOTSTRAP_TEST_ROOT, "tests\Fixtures\DevelopmentEnvironment.Probe.ps1")) -Mode Verify'
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
        $output = & $env:BOOTSTRAP_TEST_WINDOWS_POWERSHELL -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0) { throw 'The genuinely inherited signing-workflow Windows PowerShell child failed.' }
        $child = $output | ConvertFrom-Json -ErrorAction Stop
        [pscustomobject] @{ ParentEdition = $PSVersionTable.PSEdition; ParentModulePath = $env:PSModulePath; Child = $child } |
            ConvertTo-Json -Depth 8 -Compress
        exit 0
    }

    $firstPath = $env:PSModulePath
    & $bootstrap
    $utility = Get-Command Import-PowerShellDataFile -ErrorAction Stop
    $security = Get-Command Get-AuthenticodeSignature -ErrorAction Stop
    $root = $env:BOOTSTRAP_TEST_ROOT
    $dependencies = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'scripts\DevelopmentDependencies.psd1') -ErrorAction Stop
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'FabricCapacityOverage\FabricCapacityOverage.psd1') -ErrorAction Stop
    $versions = @{} + $dependencies
    foreach ($dependency in $manifest.RequiredModules) { $versions[$dependency.ModuleName] = $dependency.ModuleVersion }
    $resolved = @(foreach ($name in $versions.Keys) {
        Import-Module $name -RequiredVersion $versions[$name] -ErrorAction Stop
        $module = Get-Module -Name $name | Where-Object { $_.Version -eq [version] $versions[$name] } | Select-Object -First 1
        if ($null -eq $module) { throw "The native host could not load pinned dependency '$name'." }
        [pscustomobject] @{ Name = $name; Version = $module.Version.ToString(); ModuleBase = $module.ModuleBase }
    })
    [pscustomobject] @{
        Edition = $PSVersionTable.PSEdition
        NativeHome = $PSHOME
        UtilitySource = $utility.Source
        UtilityModuleBase = $utility.Module.ModuleBase
        SecuritySource = $security.Source
        SecurityModuleBase = $security.Module.ModuleBase
        ModulePath = @($env:PSModulePath -split ';')
        Idempotent = $firstPath -ceq $env:PSModulePath
        Dependencies = $resolved
    } | ConvertTo-Json -Depth 8 -Compress
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
