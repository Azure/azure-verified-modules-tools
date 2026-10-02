# Bicep e2e case-local post hook

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Allow an optional `post.ps1` beside one Bicep `tests/e2e/<case>/main.test.bicep`.
Execute the hook once under the existing test identity after post-deployment
assertions (or a failed deployment attempt) and before the ordinary guarded
cleanup. Do not run it for discovery, integration-only checks, dry runs or
cases without a deployment attempt. Report absence as `not-present`, and
record execution or timeout failures without hiding or preventing cleanup.
Reuse the already-generated case run ID for a disposable resource group so
the post-hook context matches its template tokens, deployment name and tag.

This is module-owner-authored code with the test identity's permissions, not
a sandbox or a privileged reaper hook. Existing scope/preview/ownership
guards and the legacy registry workflow remain unchanged.

## Checklist

- [x] Preserve the paused receipt prototype outside module and test discovery;
      retain its progress record as blocked/superseded.
- [x] Inspect existing Bicep e2e result, assertion, cleanup and process
      contracts before designing the bounded hook.
- [x] Invoke an optional case-local hook only after an actual Create attempt,
      with bounded subprocess time and explicit safe case context.
- [x] Make hook failures visible and ensure cleanup always runs, including
      failures and timeouts on guarded group and scoped cases.
- [x] Add offline mock regressions for ordering, no attempt, symlink/escape
      refusal, timeout, failure and result shape; update the related help.
- [x] Run focused checks and the full pre-commit gate before staging the
      slice for commit and updating the existing review.

## Validation

- `./build.ps1 layout`: passed.
- `./build.ps1 lint`: passed; analyzer retried after transient crashes.
- Focused post-hook unit tests: seven path checks and two process/ShouldProcess
  checks passed, including one actual local PowerShell process with a case
  path containing spaces.
- Focused Bicep unit/integration/e2e fake-process component suites: 136
  passed, followed by one additional cancelled scoped-Create check; none
  skipped or failed.
- `./build.ps1 pre-commit`: layout and lint passed; 2,120 unit tests passed
  (nine skipped), 1,066 component tests passed (none skipped or failed).
  Build succeeded with 49 nonfatal warnings from mocked
  repository-management tests. No live Azure, MCR, workflow dispatch or
  production command ran.

## Blockers or dependencies

No live Azure or MCR run, new scoped Create capability, reaper change, CI
selector/cutover or recovery baseline is part of this slice. An optional
per-case hook cannot replace guarded cleanup or post-crash recovery.
