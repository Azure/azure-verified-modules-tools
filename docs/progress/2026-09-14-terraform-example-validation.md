# Terraform example validation and module coverage

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-terraform-validation-alternatives`

## Outcome

Validate Terraform examples as root configurations so reusable modules can use
deprecated variables and outputs. Compare the local modules resolved by the
examples with the repository's module entry points and warn about missing
coverage without failing otherwise successful validation.

## Checklist

- [x] Validate all Terraform examples, including examples excluded from e2e.
- [x] Report uncovered root modules and submodules as warnings.
- [x] Preserve actionable diagnostics and fail on real validation errors.
- [x] Exercise deprecated variables and outputs in an existing test module.
- [x] Cover local and transitive module references, remote sources, missing
  examples, and missing or invalid module metadata.
- [x] Update directly related documentation.
- [x] Run the required local gate and relevant real-Terraform regressions.
- [x] Commit and push the slice.

## Validation

- `.\build.ps1 pre-commit`: passed; 1,249 unit tests passed, 8 skipped,
  1 excluded; all 84 component tests passed. Repeated after the existing
  fixture changes. The existing analyzer retry handled transient failures.
- Coverage regressions include stale caller manifests, synthetic test-module
  prefixes colliding with real module names, missing metadata, and safe
  cleanup after directory creation failure.
- Scoped `.\build.ps1 integration` with
  `$PesterPreference.Run.TestExtension = '.DeprecatedInterfaces.Integration.Tests.ps1'`:
  all 7 native regressions passed against Terraform 1.15.8, including the
  existing AzAPI fixture.
- The AzAPI fixture deprecates `create_example_resources` and `resource_ids`,
  retains compatible replacements and false creation defaults, and runs
  native test assertions through a child-module wrapper.

## Blockers and dependencies

None. No production deployments or cloud-resource changes are in scope.
