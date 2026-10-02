# Manual PowerShell Gallery publication

`.github/workflows/publish-module.yml` is **manual dispatch only** and separate
from signing. It takes exactly one required string input, **`signing_run_id`**.
It never builds, re-signs or silently selects a latest successful artifact.
This code has not been pushed, triggered or used to publish a release.

## Required protected setup

Configure a protected GitHub environment named **`powershell-gallery`**, with
required reviewers, appropriate prevention of self-review, and deployment
branches restricted to **main only**. Set:

| Configuration | Value |
|---|---|
| Environment variable `ARTIFACT_SIGNING_CERTIFICATE_SUBJECT` | The same full expected publisher Subject DN configured for signing |
| Environment secret `PSGALLERY_API_KEY` | Approved PowerShell Gallery API key authorized for this module/account |

The Gallery API key is **not an Azure client secret**. Scope and expire it
appropriately for Gallery publishing. It is mapped to a process environment
variable **only in the final publish step**, never written to `GITHUB_ENV`,
outputs, provenance or summaries. The helper clears it from its process after
use and sanitizes ambiguous publication errors.
Publishing-tool restoration exports only the isolated cache directory. Every
verification/publication entrypoint bootstraps the current host's native module
path before helper imports; the Gallery publisher resolves PSResourceGet from
that path without inheriting another edition's built-ins.

This workflow has only `contents: read` and `actions: read`. It has **no**
`id-token: write`, Azure login, signing action, Azure credentials or signing role.
Use environment protection/main branch protection to keep unreviewed workflows
from accessing release configuration. Nothing here provisions setup or keys.

## Run from GitHub UI

1. Complete [a successful manual main signing run](signing.md). Record its
   **workflow run ID** from its summary, not its artifact ID.
2. Open **Actions → Publish module manually → Run workflow**, select **main**,
   and enter that ID in **`signing_run_id`**. Decimal digits only; invalid,
   zero, overflowing or injected input fails before fetching an artifact.
3. Approve the `powershell-gallery` environment using its configured reviewers.
4. Publication verifies the source, archive and signed bytes before the secret
   step. The final step revalidates source/run/attempt/artifact identity and all
   hashes/signatures, checks that the exact Gallery version is absent, and
   invokes `Publish-PSResource -NupkgPath` on **the same signed package**.
5. Record the publication summary and retained publication-audit artifact.

The source signing run must still be completed/successful, dispatched manually
on main in this repository, and its exact attempt's artifact must remain
available. A later rerun changes the attempt: an earlier artifact is not quietly
accepted. Signing source SHA must be an ancestor of current main; force-pushed
or foreign history is rejected.

## Provenance and safe verification

The fixed GitHub API checks repository IDs/names, default branch, known signing
workflow ID/path, manual event, success/completion, main branch, source SHA and
run attempt. It reads only the module **data manifest** at that validated
immutable source SHA, using an AST literal-data reader that cannot execute
commands. It never checks out arbitrary input refs or runs PR source.

Artifact selection is by the exact run ID and name
`FabricCapacityOverage-signed-<RUN_ID>-<RUN_ATTEMPT>`, with exactly one match.
Artifact IDs, repository/run/source metadata, expiration, size and GitHub's
immutable `sha256:` digest are required.

The archive is downloaded using the fixed repository/artifact API. The bearer
token is not forwarded to the storage redirect. **Raw ZIP SHA256 and paths are
validated before extraction** rather than asking a download action to extract
unverified entries first. This is why publication does not need a separate
download-artifact action.

The verifier rejects rooted/traversing/alternate-stream/reserved paths,
case-colliding duplicates, symlinks/reparse points, excessive archive size and
unexpected files. It validates the exact three-file artifact and strict package
inventory. XML uses no external resolver and prohibits DTDs.

Package SHA256 must match provenance and `SHA256SUMS`; every shipped file must
match per-file provenance. **All `.ps1`, `.psm1` and `.psd1` signatures,
timestamps and publisher Subjects are checked before packaged manifest
processing.** Verification never imports the packaged module. Literal manifest
and nuspec identity/version/GUID/dependencies must match the selected trusted
source. The publisher's source-run metadata is refreshed immediately before
publication, not accepted solely from the unsigned JSON.

## Duplicate versions, ambiguity and retries

Publishing is serialized for the entire module, with no cancellation of
in-flight publication. A no-cache lookup of the **exact official Gallery
ID/version** determines release state:

- An exact HTTP 404 means absent.
- HTTP 200 must contain that exact package's feed metadata; it means the
  version already exists and publication fails without overwriting.
- Authentication, timeout, throttling, other HTTP errors or malformed metadata
  mean **Unknown** and fail; Unknown is not treated as absent.

The PSGallery repository registration must point to the official HTTPS feed.
The publication command receives **`-NupkgPath`**, never a module folder `-Path`.
There is no automatic workflow/helper retry after upload failure. The Gallery
itself enforces immutable version conflicts.

**After an ambiguous failure, check the exact Gallery version manually before
rerunning.** If accepted, do not publish again; inspect the existing version
and audit package. If definitely absent and safe to retry, manually dispatch
again with the same validated signing run while its artifact is available. If
the feed status is unknown, stop and resolve that uncertainty. A new module
version requires a new reviewed source version and signing run.

Timestamped files remain valid after the service's three-day leaf certificate
expires; never weaken trust checks to accept expired unsigned/untrusted files.
The original signing artifact lasts seven days. An exact verified
publication-audit bundle is uploaded immutably before the secret step and
retained for fourteen days, including if the eventual Gallery operation is
ambiguous.

## Local validation (no services)

`.\scripts\Test-Module.ps1` runs the existing module tests and deterministic
release tests on either supported Windows PowerShell host. Signatures, ARM,
GitHub run metadata and Gallery responses are fixtures/mocks. No real signing,
key access, cloud provisioning or publishing occurs.

`.\scripts\Test-Package.ps1` additionally exercises actual offline PSResourceGet
packaging of staging copies with **synthetic comment blocks** and mocked
signature results, verifying exact byte preservation and artifact round trips.
These are not real signatures. Real-signature rejection is also covered.
Source trees remain unsigned. Actionlint validates all workflows separately.

- [Publish-PSResource and its NupkgPath parameter](https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/publish-psresource)
- [GitHub artifact metadata/digest/download APIs](https://docs.github.com/rest/actions/artifacts)
- [Signing setup and external permissions](signing.md)
