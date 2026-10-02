# Manual signing runbook

`.github/workflows/sign-module.yml` implements **manual dispatch only**. There
are no push, tag, PR or automatic publication triggers. This code is committed
locally; it has **not** been pushed, run, provisioned or configured in Azure or
GitHub. Source trees stay unsigned. A successful signing run produces an
immutable release artifact, **not** a Gallery publication.

## External setup required

An administrator must separately approve resources/spending and configure:

- A production Azure Artifact Signing account in the intended region.
- **Validated Public Trust identity** and an **Active production Public Trust
  certificate profile**, not Private Trust or Public Trust Test.
- An Entra application/service principal with GitHub OIDC federation; no client
  secret. Issuer: `https://token.actions.githubusercontent.com`; audience:
  `api://AzureADTokenExchange`; exact subject:
  `repo:cbattlegear/fabric-capacity-overage-estimator:environment:artifact-signing`.
- **Artifact Signing Certificate Profile Signer** explicitly assigned at that
  certificate-profile scope. Owner/Contributor alone do not grant signing.
- Read permissions for the **exact configured account and profile**. The
  straightforward option is **Reader at the signing-account scope**, alongside
  the profile-scoped signing role. Equivalent custom read permissions work;
  helpers do not insist on a role name or discover accounts across subscriptions.
- A protected GitHub environment named **`artifact-signing`**, with required
  reviewers, prevention of self-review where available, and deployment branches
  restricted to **`main` only**. Configure branch protection for main as well.

This implementation performs no provisioning, federation, grants or environment
configuration. Set these **environment variables/vars**, not client secrets:

| `artifact-signing` environment variable | Required value |
|---|---|
| `AZURE_CLIENT_ID` | Federated application's nonempty client GUID |
| `AZURE_TENANT_ID` | Tenant GUID |
| `AZURE_SUBSCRIPTION_ID` | Signing account's subscription GUID |
| `ARTIFACT_SIGNING_RESOURCE_GROUP` | Exact account resource group |
| `ARTIFACT_SIGNING_ENDPOINT` | Exact HTTPS regional `codesigning.azure.net` root endpoint |
| `ARTIFACT_SIGNING_ACCOUNT_NAME` | Exact account name |
| `ARTIFACT_SIGNING_CERTIFICATE_PROFILE` | Exact production Public Trust profile name |
| `ARTIFACT_SIGNING_CERTIFICATE_SUBJECT` | Expected **full publisher certificate Subject DN**, for example `CN=Contoso Inc, O=Contoso Inc, L=New York, S=New York, C=US` |

Obtain the expected Subject from the approved validated profile/certificate,
including its exact formatting. Do not pin a leaf thumbprint: service
certificates rotate. Configure the **same Subject** in the separate
`powershell-gallery` environment for publication verification.

## What is validated before signing

Missing configuration and non-main/nonmanual contexts fail explicitly before
Azure authentication. Checkout uses only the dispatch's immutable `github.sha`;
there is no editable ref or path input. Both host test suites, full analyzer,
manifest/help checks and offline packaging run before creating fresh staging.

Azure authentication is `azure/login` v3 via OIDC. The signing action uses
**only AzureCliCredential**: Environment, Workload Identity, Managed Identity,
shared cache, Visual Studio/Code, Azure PowerShell, Developer CLI and browser
fallbacks are explicitly excluded. Signing dependency caching and trace logging
are disabled. No Azure auth or OIDC write permissions are added to ordinary CI
or publication.

After login, the helper reads exactly the configured account and profile with
the documented **Microsoft.CodeSigning ARM API `2025-10-13`**, not subscription
discovery. It requires:

- Matching account/profile resource IDs and resource types.
- `provisioningState = Succeeded` for both.
- The protected endpoint exactly matching the account's authoritative
  `properties.accountUri`. An absent endpoint is an error, not a guessed region.
- `properties.profileType = PublicTrust`, `properties.status = Active`, and
  nonempty authoritative `properties.identityValidationId`.

The documented stable API exposes the profile's identity-validation linkage;
it does **not** expose an identity-validation GET collection. Identity IDs are
opaque (the official example uses `"123456"`), not assumed to be ARM paths or
GUIDs. The Active Public Trust profile is the service's authoritative available
validated-identity-backed signing configuration. No invented identity API,
cross-account read expansion or claim that account Reader covers an external
identity-validation resource is made.

## Run signing from GitHub

Only after a separately approved review/merge places the workflows on main and
external setup is complete:

1. Open **Actions → Sign module manually → Run workflow**.
2. Select **main**. There are no other inputs. Approve the protected environment
   using its configured reviewers.
3. Wait for the complete run to succeed. It recursively signs every **shipped**
   `.ps1`, `.psm1` and `.psd1` in fresh staging after all generated content/tests.
   `LICENSE` needs no Authenticode. The root compatibility launcher is **excluded
   from the module package**; it remains unsigned in source.
4. Read the run summary. Record the **signing run ID**, attempt, source SHA,
   package SHA256, immutable artifact ID and artifact digest.
5. Use that **run ID**, not artifact ID, in [manual publication](publishing.md).

The artifact is named
`FabricCapacityOverage-signed-<RUN_ID>-<RUN_ATTEMPT>` and contains only the signed
`.nupkg`, `release-provenance.json` and `SHA256SUMS`. Upload is immutable with
overwrite disabled; retention is seven days. Expired/deleted artifacts require
a new signing run, never a fallback to a different run.

## Signed payload verification

Signing uses **SHA256**, **RFC3161
`http://timestamp.acs.microsoft.com`**, and timestamp digest **SHA256**.
End-entity certificates last only **three days**; timestamps let correctly
signed files remain valid after leaf certificate expiry.

Every shipped code file must have `Get-AuthenticodeSignature.Status = Valid`,
the configured publisher Subject, and a nonnull timestamp certificate. Windows
performs the trust/signature validation; there is no certificate-check bypass.
All manifest-listed code is accounted for, including the loader and manifest.

Only then is the exact signed staging folder compressed with PSResourceGet.
The packed files are safely extracted and checked again before packaged
manifest processing. Per-file SHA256 values must equal signed staging, and
packaging must not mutate staging. Provenance binds module name/version/GUID,
repository, source SHA, run ID/attempt, publisher Subject and package/file hashes.
No tokens, client secrets or Gallery keys are in artifacts.

Signing the NuGet envelope alone is **not** file Authenticode. No content changes
are allowed after signing. The module keeps only Az.Accounts as a runtime
dependency; ArtifactSigning is release-tooling only.

## Action pins and references

All workflow actions use full commit SHAs, resolved from official version tags
on 2026-10-02 and recorded in `scripts\Release\ActionPins.psd1`. Versions are
annotated in YAML: checkout v5, Azure login v3.1.0, Artifact Signing v2 and
upload-artifact v4. Re-resolve/review pins explicitly when upgrading them.

- [Microsoft signing integrations](https://learn.microsoft.com/azure/artifact-signing/how-to-signing-integrations)
- [Resources, Public Trust and explicit signing roles](https://learn.microsoft.com/azure/artifact-signing/concept-resources-roles)
- [Official signing action and inputs](https://github.com/Azure/artifact-signing-action)
- [Official OIDC guidance](https://github.com/Azure/artifact-signing-action/blob/main/docs/OIDC.md)
- [Stable ARM account/profile schema](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/codesigning/resource-manager/Microsoft.CodeSigning/CodeSigning/stable/2025-10-13/codeSigningAccount.json)
