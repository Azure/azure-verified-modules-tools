# Terraform test feature registration

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-test-feature-registration`

## Outcome

Added an opt-in, root-level `.required-features.json` array of
`"Namespace/FeatureName"` strings and an `avm register-features` /
`Register-AvmFeature` command. The Terraform integration and example
end-to-end jobs conditionally register missing features only on their
individually selected test subscriptions, after the protected job
authenticates to Azure and before running tests. Registration persists after
the tests; the workflow never unregisters features.

## Checklist

- [x] Check the module command registry, process helper, workflow authentication,
      existing tests, and contributor documentation.
- [x] Validate the entire manifest and the selected subscription before any
      Azure operation; handle existing, pending, failed, and timed-out features.
- [x] Gate Azure sign-in and registration within protected Terraform test jobs,
      using the same identity and selected subscription as the tests.
- [x] Document the file format, prerequisites, permissions, lifecycle, and
      release dependency for consuming repositories.
- [x] Run focused tests, workflow validation, and the full local pre-commit gate.
- [x] Prepare the validated main-based slice for a draft review.

## Validation

`actionlint .github/workflows/terraform-module.yml` and `git diff --check`
passed. Focused PowerShell tests exercised manifest parsing, offline preflight,
per-leg identity/subscription safety, CLI arguments, existing and transitional
states, permissions, provider propagation, and timeouts using mocked Azure CLI.
The full `./build.ps1 pre-commit` gate passed: layout and lint, 1,957 unit
tests passed (9 existing skips), and 975 component tests passed. An initial
cross-platform coverage check exposed newly added commands that were exercised
only by component tests; mock-only, no-filesystem unit tests now exercise
registration and provider propagation. `./build.ps1 coverage` passed locally
at 73.87% against the 70% floor. New source and test files use UTF-8 without
BOM and LF line endings.

No live Azure registration, deployment, workflow dispatch, release, or merge
was performed or authorized by this slice.

## Blockers or dependencies

The consuming module's
[change](https://github.com/Azure/terraform-azurerm-avm-ptn-avd-lza-managementplane/pull/193)
already references the reusable workflow at `@main`, so no reference edit is
needed. It cannot benefit until this tooling is merged to `main` and a
compatible module version is released. Protected environment approvals and
Azure feature/provider registration permissions remain requirements for
actual runs.
