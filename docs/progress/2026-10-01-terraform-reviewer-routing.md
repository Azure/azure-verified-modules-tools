# Terraform reviewer routing

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-terraform-reviewer-workflow`

## Outcome

Extended the existing scheduled reviewer-routing workflow to active Terraform
module repositories in the AVM App installation. Discovery shares repository
sync's provider and naming rules, uses a separate read-only token, and scopes
the writer to selected Bicep/Terraform targets only.

Frequent runs search batches of twenty Terraform repositories, then retrieve
current request details only for candidates. Incomplete, over-cap, changing,
or failed searches fall back to per-repository lists. Daily and zero-minute
sweeps always use full repository pagination, without the former 500-request
limit. The published catalog is read once per run.

Terraform files, examples, and child modules resolve to root ownership.
Changed root metadata overrides the catalog at the request head; unindexed
roots use the same fallback. Bicep path rules, labels, orphan-team fallback,
reviewer exclusions, dry runs, and per-request isolation remain shared.
Requests that become drafts or close after search discovery are skipped.
One failed repository does not stop the remaining targets.

## Checklist

- [x] Read repository guidance and active or blocked progress records.
- [x] Check the existing feature branches and open routing work.
- [x] Trace shared ownership, discovery, token, and routing helpers.
- [x] Implement Terraform routing in the existing workflow.
- [x] Cover fleet discovery, metadata overrides, and shared routing rules.
- [x] Update directly related operational documentation.
- [x] Run the local pre-commit gate and prepare the completed slice for publication.

## Validation

`.\build.ps1 pre-commit` passed layout and lint, 2,104 unit tests, and 935
component tests with zero failures. Nine unit tests were skipped. The final
focused `.\build.ps1 pre-commit -TestName ...` passed layout, lint, 228
shared routing/discovery unit tests, and 114 shared-metadata component tests.
This gate also covered the final URL-normalization correction: repository
names ending in `repos` or `pulls` remain intact for ordinary and API URLs.
Tests cover exact search batching,
pagination, the 1,000-result boundary, incomplete results, installation
scope failures, head-metadata overrides, reviewer exclusions, idempotency,
dry runs, and request/repository failure isolation.

A read-only GitHub query using twenty exact repositories and a 1,243-character
query succeeded with `incomplete_results: false`. Published Terraform catalog
records were confirmed to use `modulePath: "."` for roots. GitHub CLI's
repository lister was checked to paginate without search or up-front
limit-sized allocation; a live read-only listing accepted the complete-list
limit and returned the same two open storage requests as the search probe.

Changed files use UTF-8 without BOM and LF endings. `git diff --check` passed.

## Blockers or dependencies

No source blockers. Live reviewer/label changes, workflow dispatch, and
production configuration changes were not performed. Merging this change
extends the existing scheduled workflow; an app-token dry run remains an
operator-approved runtime check.

The workflow fails explicitly if the selected fleet exceeds GitHub's
500-repository scoped-token limit; such growth requires splitting the fleet
into scoped jobs. Current public catalog inspection found 232 Terraform roots.
The installation, not that catalog count, defines runtime coverage.

The team documentation in `Azure-Verified-Modules-Docs` should also record
Terraform coverage and the manual dry-run options.
