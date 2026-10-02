# Bicep symbolic template safety

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Inspect ARM languageVersion 2.0 symbolic resource objects in scoped Bicep
end-to-end preflight, while retaining the existing scope and resource
allowlist. Recognize only reviewed, outputs-only AVM telemetry nested
templates with no resource writes. Ground regressions in a pinned registry
example compiled offline with the repository-pinned Bicep version.

## Checklist

- [x] Review the pinned compiled example and record an offline fixture.
- [x] Inspect symbolic resources and exact telemetry-only nested templates.
- [x] Reject malformed, unsafe, linked, cross-scope, and non-telemetry empty
      templates before Azure access in unit and mocked component tests.
- [x] Update public help with precise limitations.
- [x] Run the full local gate and coverage.

## Fixture provenance

`tests/fixtures/bicep-scoped/role-definition-mg-default.6eb8e6ff.json`
is the unmodified ARM output of Bicep 0.47.16 from the
[management-group role-definition example](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/avm/ptn/authorization/role-definition/tests/e2e/mg.default/main.test.bicep).
The source commit and this repository are MIT-licensed. The fixture was
compiled locally without Azure or a remote module restore; its top-level
and nested generator hashes matched the `--stdout` output.

## Validation

Focused `./build.ps1 test,component -TestName ...`: 27 unit and 34 component
tests passed. `./build.ps1 pre-commit`: layout and lint passed, 1,990 unit
tests passed (9 skipped), and 1,020 component tests passed.
`./build.ps1 coverage`: 72.39%, above the 70% floor. The pinned management
group fixture reaches mocked ARM validation, not a full deployment; its
role-definition GUID does not satisfy existing run-unique ownership checks.
Local Bicep compilation and mocked processes only; no live Azure, MCR,
registry CI or selector change was made. Remote CI status is pending push.

## Blockers or dependencies

This parser change does not approve subscription-to-resource-group
deployments, Update/NoChange operations, new resource families, target
leasing, or crash recovery. The pinned registry inventory found no
currently proven runnable higher-scope case.
