# Test pruning and integration fixtures

- **Status:** complete
- **Started:** 2026-10-05
- **Completed:** 2026-10-05
- **Branch:** `jaredfholgate-avm-authoring-refactor`
- **Parent record:** [2026-10-03-avm-authoring-refactor.md](2026-10-03-avm-authoring-refactor.md)

## Outcome

Replaced scattered "is this command exported" checks with one exact-set test, and added a Bicep integration fixture for existing-resource references.

## Checklist

- [x] Scan the suite for redundant tests (2,834 `It` blocks). Source-text tests are almost gone. The remaining ones guard repository-management workflow architecture and stay. Tests that share a name within a file cover different contexts or targets and stay.
- [x] Remove the 13 per-command `is exported by the manifest` tests under `tests/Pester/Unit/Public/`, plus 6 single-command export tests in `tests/Pester/Unit/Module/Avm.Authoring.Tests.ps1`.
- [x] Replace them with one test that the loaded module exports exactly the manifest's `FunctionsToExport`, and exactly one function per `Public/*.ps1` script. This catches missing and leaked exports, which the old tests did not. The three private-helper leak checks became one data-driven test. The alias, back-compat shim and `SkipModuleVersionCheck` checks are unchanged.
- [x] Add `tests/Pester/Integration/BicepExistingReferences.Integration.Tests.ps1`. It compiles a template with an existing Microsoft Graph service principal and an existing Key Vault (2026-02-01) whose `.id` is forwarded to a child module. It asserts symbolic `languageVersion` 2.0, the remaining parameters, existing-reference handling, and that the docs resource walker reports no deployable resources. It is skipped when `AVM_OFFLINE=1`.

## Validation

- Focused: `tests/Pester/Unit/Module/Avm.Authoring.Tests.ps1` and `tests/Pester/Unit/Public`: 326 passed.
- Integration fixture: 1 passed, 2.5s, using the cached Bicep compiler.
- Gate: `./build.ps1 pre-commit` passed in 12m14s. Unit: 2,959 passed (was 2,977; 19 export checks removed, 1 exact-set test added). Component: 1,280 passed, 1 skipped.
