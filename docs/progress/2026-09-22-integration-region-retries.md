# Integration region retries

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-integration-region-retries`

## Outcome

Retry Terraform integration tests on recognized Azure capacity and region
availability failures, using the existing E2E retry classification and bounds.
Preserve assertions, failure status, authentication, test selection, and
Terraform-owned cleanup. No workflow trust or cloud configuration changes.

## Contract

- E2E currently defaults to two retries, allows zero through ten, and adds no
  delay. A successful destroy precedes each retry; fixture state then selects
  the region again. Idempotency failures are not retried.
- Integration retries must wait for Terraform test teardown to finish and
  refuse retries after assertions, unknown errors, authorization failures,
  cleanup failures, or interruption. Region-ineligible errors require specific
  evidence, not merely HTTP 403.
- Each retry reruns the same test target with unchanged arguments and
  environment. Terraform, not the runner, owns test state and resource cleanup.
- Replay requires matching `test_abstract`, terminal `test_run`, per-file
  `test_file` teardown/complete, and final `test_summary` events. Cleanup
  diagnostics, `test_cleanup`, and interruption veto replay. A recovered
  attempt must also report a complete pass. Files mentioning `skip_cleanup`,
  `state_store`, or `backend` still run once but disable automatic replay.
- The E2E-only custom retry regex does not broaden integration eligibility.
  Empty or skipped integration execution cannot recover a prior failure or
  report a pass; absent integration tiers retain their existing skipped status.
- The Example integration setup already chooses a recommended region with
  `random_integer.region_index`. A new test invocation can select another
  region without modifying the fixture or deleting state.

## Checklist

- [x] Read the repository contract and active progress records.
- [x] Verify clean HEAD against remote main and check related open work.
- [x] Inspect E2E, integration, workflow installation, and Example region setup.
- [x] Implement bounded integration retries and the public CLI parameter.
- [x] Add deterministic offline coverage for retry, cleanup, failure, and CLI behavior.
- [x] Update directly related command documentation.
- [x] Run focused tests and the mandatory pre-commit gate.
- [x] Keep live deployments, approval, merge, and publication outside this slice.

## Validation

- Initial and pre-edit HEAD/remote main:
  `9480046a8c2578f4dbf4909f99c9e28cf2d782f2`.
- Focused offline unit and component run passed: 147 unit and 11 component
  tests. The real-subprocess fixture exercised a restricted first region, its
  cleanup, and a second eligible region, plus cleanup failure, assertion
  failure, inherited test filters, and the CLI retry-disable override.
- `.\build.ps1 test -TestName @('Terraform integration retry*', '*encoding*')`
  with `AVM_OFFLINE=1`: 85 passed, zero failures, including the final malformed
  output, recovered-attempt completion, and LF/UTF-8 checks.
- Final `pwsh -NoProfile -File .\build.ps1 pre-commit`, with `AVM_OFFLINE=1`
  and the repository CI setting `DOTNET_MultiCoreJitMinNumCpus=7fffffff`:
  layout and lint completed; 1,705 unit tests passed, 9 skipped; 907 component
  tests passed, 1 skipped; zero failures. Lint reported 171 warnings in
  unchanged sources, with none in the changed PowerShell sources.
- An initial analyzer runtime failure was retried through the existing build
  entry point, without changing analyzer settings or suppressing diagnostics.
- No Azure deployments, state inspection, workflow dispatches, reruns,
  approvals, merges, or package publication are part of this slice.

## Dependencies

The reusable integration job installs Avm.Authoring from PowerShell Gallery
after its protected-environment gate. Its optional `avm-authoring-version`
input defaults to the latest published package, not the Tools checkout.
Source merge and package publication are required before the normal Example
run can prove the new retry behavior. The coordinating session owns release
approval and verification of the actual installed version and integration run.
The current signed stable release path is the Azure DevOps
`release-avm-authoring.yml` pipeline, then `.github/workflows/release.yml` and
`scripts/Publish-AvmAuthoring.ps1`. The publisher rejects prereleases; a new
maintainer-selected stable tag containing this change must reach the Gallery.
No reusable-workflow YAML change is required for the retry default. A stable
release newer than the observed `0.17.0` must contain this source; its exact
version remains the release owner's decision. Live Example integration success
has not been verified by this slice.
