# Development, testing and offline packaging

## Layout

```text
FabricCapacityOverage\
  FabricCapacityOverage.psd1       # Version/GUID/export/dependency metadata
  FabricCapacityOverage.psm1       # Definition loader; no authentication
  LICENSE                         # Shipped MIT license
  Public\Get-FabricCapacityOverageCost.ps1
  Private\                        # Authentication, API, discovery, refresh, replay
tests\                            # Deterministic Pester suites and fixtures
tests\Packaging\                  # Actual nuspec and disposable-install checks
examples\
scripts\
docs\
Get-FabricCapacityOverageCost.ps1  # Local compatibility launcher, not standalone
```

Only `Get-FabricCapacityOverageCost` is exported. Keep helpers private and pass
the invocation context explicitly; do not add module-global workspace, price,
token or preference state. The original canvas migration source included
timestamp, refresh and ShouldProcess fixes that were not yet on the old script's
main branch; those behaviors are covered by committed regression tests.

Release verification helpers live under `scripts\Release\`, outside the shipped
module. Signing/publishing workflows are separate, manual-only and main-only;
ordinary test CI has no Azure auth, OIDC write or Gallery credentials.

## Development dependencies

Pinned development versions are in `scripts\DevelopmentDependencies.psd1`:
Pester 5.7.1, PSScriptAnalyzer 1.25.0 and PSResourceGet 1.2.0. They are not runtime
dependencies and are never included in the module's nuspec. The only runtime
dependency is Az.Accounts 5.5.3+.

Use already installed tools when available. If validation reports missing
modules, restore them into a **disposable directory**, not your usual module
directories. In PowerShell 7 with PSResourceGet available:

```powershell
$cache = Join-Path $env:TEMP ('overage-dev-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $cache
$dependencies = Import-PowerShellDataFile .\scripts\DevelopmentDependencies.psd1
foreach ($name in $dependencies.Keys) {
    Save-PSResource -Name $name -Version $dependencies[$name] -Repository PSGallery -Path $cache -TrustRepository
}
Save-PSResource -Name Az.Accounts -Version 5.5.3 -Repository PSGallery -Path $cache -TrustRepository
$env:FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE = $cache  # Current process/children only
.\scripts\Initialize-DevelopmentEnvironment.ps1
```

These restores download public tools only; they do not sign in, install the Az
bundle or change repository trust settings. On a machine without PSResourceGet,
obtain it using the approved development-tool installation method first.

## Offline validation

```powershell
.\scripts\Test-Module.ps1
.\scripts\Test-Module.ps1 -TestPath .\tests\Replay.Tests.ps1
.\scripts\Test-Module.ps1 -CodeCoverage -ResultPath .\.build\TestResults.xml
```

The command validates the real manifest, import/export and help, runs the full
default analyzer over module/launcher/scripts/tests/examples with **no
suppressions**, and runs the core and release Pester suites. Any analyzer finding or
failed test terminates validation. Release suites also exercise provenance,
signature/timestamp/publisher checks, unsafe archives and workflow constraints.
Tests use fixed tokens, clocks, HTTP
envelopes and native CLI fixtures: **no actual model queries, login or service
refreshes**. A custom test host exercises a genuinely declined `Confirm`.

Coverage includes decimal pricing, incoming debt, full idle burndown, separate
recorded payments, future-smoothed demand, historical SKU sizes, lifecycle
resets, cumulative-debt double counting, discovery/scoping/chunking, typed
timestamps, exact fractional freshness thresholds, permission failures,
truncation/missing joins, refresh request matching/failure/timeout/WhatIf,
compatibility forwarding and repeated invocation isolation.

Run the same core command in Windows PowerShell 5.1 and PowerShell 7 on Windows.
Share **only the cache location**, not one edition's entire `PSModulePath`.
Runner restoration writes `FABRIC_CAPACITY_OVERAGE_DEPENDENCY_CACHE` to
`GITHUB_ENV`; every validation, packaging and manual release entrypoint calls
the shared native bootstrap before metadata or helper imports. Each process
puts its own `$PSHOME\Modules` first, adds the existing cache once, preserves
ordinary local/custom module scopes, and removes inherited peer-edition
built-in roots. Utility and Security command metadata must resolve natively.
A configured missing cache fails explicitly; bootstrap never installs tools.

The signing workflow also initializes its actual Windows PowerShell child
before evaluating path expressions: a bootstrapped PS7 parent still passes
PS7 built-in directories to its children. Fresh-process regressions reproduce
the original contaminated 5.1 data-import failure and cover this nested child,
both native editions, empty/duplicate paths, and local runs without a cache
variable or GitHub Actions. Existing local installations/custom module paths
remain usable when the dedicated cache variable is absent.

Respect organizational execution policies. On the
migration machine, unsigned scripts needed `-ExecutionPolicy Bypass` **only on
the test child process**, not `Set-ExecutionPolicy` or an OS/user policy change.
No Linux/macOS support is asserted. CI repeats the core checks on Windows with
both `pwsh` and `powershell`, using public dependencies and no secrets.

## Build and inspect the actual package

In PowerShell 7.4+:

```powershell
.\scripts\Build-Package.ps1 -DestinationPath .\.build\packages
.\scripts\Test-Package.ps1 -DestinationPath .\.build\packages
```

PSResourceGet's `Compress-PSResource` builds the `.nupkg` from **only** the root
module folder, with manifest validation enabled. `Test-Package` examines the
actual nuspec, not merely the manifest: Az.Accounts must be the sole dependency,
with inclusive minimum 5.5.3 and no upper bound. It checks identity, tags, license
URI, shipped MIT license and every public/private file. It rejects accidentally
packaged tests, development tools or the root launcher.

PSResourceGet 1.2 encodes the actual dependency as
`<dependency id="Az.Accounts" version="5.5.3" />`. In NuGet range notation a bare
`5.5.3` means **5.5.3 or newer**, not the exact-version constraint `[5.5.3]`.

The smoke test extracts the package into a versioned Pester TestDrive module
directory, validates its manifest and imports it in a fresh runspace. This is a
disposable **manual offline installation**, with the required Az.Accounts already
available; it does not exercise Gallery dependency downloading. TestDrive is
removed afterward. No normal installed modules or repository registrations
are changed.

PSResourceGet 1.2 stores registrations in a fixed per-user
`LocalApplicationData\PSResourceGet\PSResourceRepository.xml`; it has no public
per-invocation store option. Do **not** register a temporary feed in a shared
developer profile or patch internal fields to simulate isolation. Native local
`Publish-PSResource`/`Install-PSResource` testing needs a separately approved
disposable user/runner environment; it is not performed by these scripts.

Packages and optional reports stay under ignored `.build\` by default. Normal
development packaging is unsigned and offline, never a publication. The package
suite also builds real nupkgs from copies with synthetic signature comments and
mocked certificate results to prove byte preservation; it does not sign code.
For an approved manual release, finalize/sign staged files first and package
without modifying them; see [signing](signing.md) and [publishing](publishing.md).
Ordinary CI has no signing or Gallery publishing.

## References

- [Compress-PSResource](https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/compress-psresource)
- [PSResourceGet supported repositories](https://learn.microsoft.com/powershell/gallery/powershellget/supported-repositories)
- [PSResourceGet 1.2 repository-store implementation](https://github.com/PowerShell/PSResourceGet/blob/v1.2.0/src/code/RepositorySettings.cs)
- [NuGet version-range notation](https://learn.microsoft.com/nuget/concepts/package-versioning#version-ranges)
- [Pester documentation](https://pester.dev/docs/quick-start)
