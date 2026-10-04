# Bounded retry for network IO and fewer redundant requests

- Status: complete
- Started: 2026-10-04
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

User-directed addition to the refactor: every network-performing path either uses one shared, bounded retry for transient failures or is documented as already covered by its own client. Avoidable repeat requests are removed.

## Shared mechanism

- `Resources/network.json` holds the limits (4 attempts, 2 s initial delay, 30 s cap, Retry-After honoured up to 120 s, 2 attempts for advisory lookups), the transient HTTP status codes and the transient message patterns. `AVM_NETWORK_RETRY_MAX_ATTEMPTS` (1–10) overrides the attempt count.
- `Private/Network/`: `Get-AvmNetworkRetryPolicy`, `Get-AvmNetworkFailureKind` (Transient, Permanent or Cancelled; normalises ANSI codes, line wraps and Terraform box borders before matching), `Get-AvmRetryAfterDelay`, `ConvertFrom-AvmRetryAfterHeader`, `Wait-AvmRetryDelay`, `Invoke-AvmRetry` and `Invoke-AvmWebRequest`.
- Backoff is capped exponential with jitter, never shorter than a server `Retry-After`; a `Retry-After` above the cap stops retrying. The final failure is the original error, preceded by one warning naming the attempts. `-RetryQuiet` sends retry progress to Verbose for advisory callers that report failure themselves.
- Authentication (401, 403, credential messages), configuration (`AvmConfigurationException`, offline mode), not-found and cancellation are never retried.
- `Invoke-AvmProcess -RetryNetworkFailure` and `Invoke-AvmGit -RetryNetworkFailure` opt a subprocess in. Timeouts are marked non-transient so the timeout budget is not multiplied.
- Repository scripts outside the module dot-source `scripts/Import-AvmNetworkRetry.ps1`, which loads the same helpers and config.

## Coverage inventory

| Path | Coverage |
| --- | --- |
| Tool, pinned-asset and schema downloads (`Invoke-AvmHttp`) | Shared retry through `Invoke-AvmWebRequest`; SHA verification unchanged. |
| API spec list, MCR tag list, catalog telemetry prefix | Shared retry; 5xx and 429 retried, last response still reported by the caller. |
| PowerShell Gallery update check (`Get-AvmLatestModuleVersion`) | Advisory budget, quiet; cached once per session as before. |
| `avm update` (`Update-PSResource`) | Retried only after `Get-InstalledPSResource` shows the target version is still absent. |
| GitHub API (`Invoke-AvmGitHubApi`) | GET only. POST, PUT, PATCH and DELETE are never retried. |
| Git `ls-remote`, fetch, clone | Shared retry. Push is never retried. |
| `terraform init`, `tflint --init`, MAPOTF transform | Shared retry; the separate MAPOTF loop and `Test-AvmMapotfTransientProviderError` were removed and their patterns moved to `network.json`. |
| `Install-AvmBuildPrerequisites.ps1` | Shared retry; an exact pin that is already installed is skipped. Version ranges still resolve against the Gallery. |
| `Save-AvmAuthoringReleaseAssets.ps1` | `gh api` listing and each asset download retried. |
| `Publish-AvmAuthoring.ps1` | `Find-PSResource` retried for transient errors only; exhaustion fails before publishing. `Publish-PSResource` is never retried. |
| `Update-AvmPins.ps1` | Its three release lookups use the shared retry. |
| Azure CLI, Az PowerShell, Bicep registry restore | Not wrapped: their Azure SDK clients already retry, and wrapping would multiply budgets. |
| Bicep native deployment and cleanup | Unchanged: existing reconcile-before-retry logic; deployments are never replayed. |
| Terraform capacity and region retries | Unchanged: they handle Azure capacity, not network failures, and `terraform init` runs outside them, so budgets do not nest. |
| Repository-management scripts and catalog collection | Out of module scope; they keep their existing `RetryHelpers.ps1` and catalog delay logic. |

## Redundant requests removed

- `Initialize-AvmTerraformRepository` fetched the repository metadata twice; it now reuses the first result.
- The build prerequisites script no longer reinstalls an exact pinned module that is already present.

## Checklist

- [x] Inventory existing retry and cache mechanisms.
- [x] Shared helpers, config and script loader.
- [x] Opt in every network read listed above; leave mutations unretried.
- [x] Tests: transient then success, exhaustion, non-retryable, cancellation, Retry-After, update reconcile, publish safety, request counts.
- [x] Spec, quality standards and CHANGELOG.
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- `NetworkRetry.Tests.ps1`: 27 tests in about 8 s, all with mocked delays.
- Affected unit suites (update, version, transform, API spec, MCR tags, catalog, managed-files version, process, installation): 163 passed after fixes. Script suites: install 4/4, release assets passed, publish component 7/7.
- ./build.ps1 pre-commit: green in 9m50s (2,947 unit tests; component shards 159, 154, 148, 150, 316 with 1 skip, and 348; no failed containers).
