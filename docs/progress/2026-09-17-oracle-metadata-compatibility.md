# Oracle metadata compatibility

**Status**: complete
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-oracle-metadata-compatibility`

## Outcome

Supports the real ARM canonical types
`Oracle.Database/cloudExadataInfrastructures`,
`Oracle.Database/cloudVmClusters`, and
`Oracle.Database/autonomousDatabases` throughout metadata authoring,
validation, discovery, and catalog generation. Preserves strict namespace and
resource-segment syntax, resource ownership and telemetry, reduced-child
inheritance, and pattern/utility taxonomy unchanged.

One private classifier is shared by metadata validation, fallback discovery,
and the optional Bicep source-inference adapter. Catalog record splitting already
preserved the namespace and remaining resource path; its behavior is unchanged
and now covered for Oracle in both JSON and CSV output.

## Checklist

- [x] Read the agent contract and active progress; confirm the clean worktree
      starts at current `origin/main`
      (`0d30f8c333f87703f3924d0758699ce7ad91e231`) with no overlapping open change.
- [x] Trace Microsoft-only assumptions in schemas, classification, authoring,
      discovery, and catalog handling.
- [x] Add scoped `Oracle.Database` compatibility and regressions for roots,
      reduced children, fallback discovery, initialization, and catalog output.
- [x] Preserve rejection of synthetic family-qualified ARM types and other
      malformed canonical values.
- [x] Update tools-repository docs for the agent-led, metadata-only Terraform
      migration and the compatible installed/released-schema prerequisite.
- [x] Run focused `build.ps1` selectors and the full `pre-commit` gate.
- [x] Inspect the diff and prepare one coherent feature-branch change for
      commit, push, and review.

## Validation

- Before implementation, `.\build.ps1 component -TestName '*Oracle*'` reproduced
  33 failures across the new compatibility cases.
- `.\build.ps1 test -TestName 'Metadata*'`: 80 passed.
- `.\build.ps1 component -TestName '*Oracle*'`: 69 passed.
- The first full gate identified CRLF in the newly added classifier. The new
  files were normalized to UTF-8/LF; the focused encoding guard passed all
  3 tests.
- `.\build.ps1 pre-commit`: passed, 5 tasks and 0 errors; 1,582 unit tests passed
  (8 skipped), and 667 component tests passed (1 skipped). The configured
  analyzer and guard-fixture warnings remain visible; no gate was skipped.

## Dependencies and boundaries

- Companion public documentation:
  [Azure/Azure-Verified-Modules#2936](https://github.com/Azure/Azure-Verified-Modules/pull/2936).
  Its owner will update the tooling dependency separately.
- Local code and CI success are not a release. Consumers need an installed,
  released `Avm.Authoring` package with compatible schemas before adoption.
- The current one-off migration uses reviewed inclusion/exclusion decisions,
  preserves valid metadata and owners, and creates no Terraform wiring.
  Ordinary full repository sync's optional metadata hook remains unchanged.
- No production workflows, releases, target-repository backfills, permission
  changes, credentials, App authentication, or Azure operations are in scope.
