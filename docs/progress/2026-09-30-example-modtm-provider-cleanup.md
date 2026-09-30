# Example modtm provider cleanup

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Apply the existing guarded MaPoTF removal of unused `modtm` provider
requirements to examples as well as standalone test modules. Do not remove a
requirement when an authored `modtm` resource or data source still uses it,
and do not weaken unrelated TFLint rules.

## Checklist

- [x] Share one provider-cleanup profile between example and test scopes.
- [x] Cover unused, used, and absent provider declarations and transform
      idempotence with real MaPoTF and Terraform tests.
- [x] Update the profile inventory and directly related documentation.
- [x] Pass the local pre-commit gate, commit, and push the change.

## Validation

The focused real-MaPoTF cases passed for unused, authored, and absent `modtm`
example declarations, and the prior standalone test-module migration passed.
An offline transform of the exact staged AI gateway candidate removed both
example-only `modtm` requirements, left other TFLint findings intact, and
produced no drift on a second pass. `./build.ps1 pre-commit` passed with 1,958
unit tests, nine platform skips, 941 component tests, and no failures after
fixing two scheduler tests that used nonexistent mocked example paths. No
live repository sync or Azure operation ran.

## Blockers or dependencies

The cancelled [fleet preview](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36749306675)
found example scopes whose `required_providers.modtm` survived the root
telemetry migration and triggered `terraform_unused_required_providers`.
Version-pin, interface, and authored test failures remain outside this slice;
no new live run or Azure operation is authorized.
