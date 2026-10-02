# Signing and release runbook (not enabled)

**Guidance only.** No cloud signing, provisioning, RBAC assignments, repository
secrets, paid resources or Gallery publication are implemented by this migration.
The ordinary CI workflow has no Azure login, OIDC write permission, signing job
or publishing job. The current module is unsigned. Do not assume it will load
under an organization's AllSigned policy.

## Azure Artifact Signing prerequisites

An owner must separately approve the service, region, subscription and spending.
For public PowerShell distribution, the account needs **validated Public Trust
identity** and a production **Public Trust certificate profile**. Private Trust
and Public Trust Test profiles are not substitutes for public distribution.

Use an Entra application/service principal or other supported workload identity
with narrowly scoped GitHub OIDC federation. Prefer a subject restricted to
`repo:cbattlegear/fabric-capacity-overage-estimator:environment:<PROTECTED_RELEASE_ENVIRONMENT>`,
with that environment restricted to approved release tags and reviewers. Validate
the actual subject/audience in the future release design. Do not create a broad
repository-wide federation or a long-lived client secret.

The signer needs **Artifact Signing Certificate Profile Signer**, assigned
explicitly at the intended **certificate-profile scope**. Owner/Contributor alone
does not grant signing rights. Administrative setup and signing are separate
privileges. Do not grant subscription-wide signing access for this module.

| Placeholder | Owner must supply/verify |
|---|---|
| `<AZURE_TENANT_ID>` | Tenant containing the approved signing identity |
| `<AZURE_CLIENT_ID>` | Federated application's client ID |
| `<AZURE_SUBSCRIPTION_ID>` | Subscription containing the signing account |
| `<PROTECTED_RELEASE_ENVIRONMENT>` | Protected GitHub release environment and federation subject |
| `<SIGNING_ENDPOINT>` | Service endpoint matching the account/profile's region |
| `<SIGNING_ACCOUNT_NAME>` | Approved Artifact Signing account |
| `<PUBLIC_TRUST_PROFILE_NAME>` | Validated production Public Trust certificate profile |
| `<STAGED_MODULE_DIRECTORY>` | Final, immutable module content, not tests/development tools |

## Future protected release flow

1. Approve a protected version tag/environment release, never an ordinary PR.
2. Restore development dependencies; run tests, analyzer, manifest and package
   checks. Finalize version, help, documentation and license content.
3. Stage the final module. Authenticate with OIDC on a supported Windows x64
   runner (`windows-2022` or `windows-2025`; the action does not support ARM).
4. Sign **all shipped `.ps1`, `.psm1` and `.psd1` files recursively** using SHA256
   and RFC3161 timestamping. If distributing the root compatibility launcher
   separately, sign it too.
5. Verify file Authenticode status, signer identity and timestamp on Windows;
   re-import and inspect the final package. No source/content changes after
   signing; rebuild/re-sign if anything changes.
6. Package the signed files and approve Gallery publication separately. Gallery
   credentials are not signing credentials and must not be available to PR jobs.

The official integrations include SignTool, the GitHub Action and the Gallery
`ArtifactSigning` module. Any signing module is **development/release-only**, not
a runtime `RequiredModule` of FabricCapacityOverage.

The following **non-executable documentation fragment** lists verified action
inputs; it is deliberately not a workflow and has unresolved placeholders:

```yaml
# FUTURE protected release only. Not enabled or stored under .github/workflows.
# Job requires the approved environment and id-token: write, contents: read.
- uses: azure/login@v3
  with:
    client-id: <AZURE_CLIENT_ID>
    tenant-id: <AZURE_TENANT_ID>
    subscription-id: <AZURE_SUBSCRIPTION_ID>
- uses: azure/artifact-signing-action@v2
  with:
    endpoint: <SIGNING_ENDPOINT>
    signing-account-name: <SIGNING_ACCOUNT_NAME>
    certificate-profile-name: <PUBLIC_TRUST_PROFILE_NAME>
    files-folder: <STAGED_MODULE_DIRECTORY>
    files-folder-filter: ps1,psm1,psd1
    files-folder-recurse: true
    file-digest: SHA256
    timestamp-rfc3161: http://timestamp.acs.microsoft.com
    timestamp-digest: SHA256
```

Pin reviewed action commit SHAs when implementing the protected workflow. The
current documented integration versions are `azure/login@v3` and
`azure/artifact-signing-action@v2`; check official instructions again before
enabling them. Do not copy the upstream main-branch-trigger example into this
repository.

## Verification and package distinction

Artifact Signing end-entity certificates last **three days**. Timestamping is
essential for signatures to remain valid after certificate expiry; use the
service RFC3161 timestamp endpoint above with SHA256.

For a future signed staging directory:

```powershell
$signatures = Get-ChildItem -LiteralPath '<STAGED_MODULE_DIRECTORY>' -Recurse -File |
    Where-Object Extension -in '.ps1', '.psm1', '.psd1' |
    Get-AuthenticodeSignature
$signatures | Select-Object Path, Status, SignerCertificate, TimeStamperCertificate
if (@($signatures | Where-Object { $_.Status -ne 'Valid' -or $null -eq $_.TimeStamperCertificate }).Count -gt 0) {
    throw 'Release files need valid, timestamped Authenticode signatures.'
}
```

Also verify the expected signer/profile and a trusted chain, not just the
presence of a signature. This is verification guidance, not a signing command.
Signing only the `.nupkg` NuGet envelope does **not** Authenticode-sign its
PowerShell files. An optional signed file catalog can cover other package
content, but does not replace required file signatures.

## Verified references

- [Microsoft signing integrations](https://learn.microsoft.com/azure/artifact-signing/how-to-signing-integrations)
- [Official Artifact Signing Action, inputs and Windows requirements](https://github.com/Azure/artifact-signing-action)
- [Official OIDC guidance](https://github.com/Azure/artifact-signing-action/blob/main/docs/OIDC.md)
- [Artifact Signing resources and roles](https://learn.microsoft.com/azure/artifact-signing/concept-resources-roles)
- [Azure PowerShell signing integration](https://learn.microsoft.com/azure/artifact-signing/how-to-signing-integrations#powershell)
