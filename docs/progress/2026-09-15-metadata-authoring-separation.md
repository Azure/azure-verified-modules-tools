# Metadata authoring and migration separation

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Keep Avm.Authoring's metadata commands useful after migration: read existing
metadata, validate it, and initialize files from supplied values. Move CSV
conversion and backfill-only source inference outside the packaged module into
the disposable repository-management migration area.

Both normal authoring checks will validate local metadata. The user confirmed
that missing files must produce warnings, not failures, during rollout.
Neither authoring check may depend on CSV indexes or run migration.

## Checklist

- [x] Separate temporary conversion helpers and callers from Avm.Authoring.
- [x] Make Get-AvmModuleMetadata an existing-file reader only.
- [x] Add metadata validation to pre-commit and pr-check, warning on missing files.
- [x] Initialize new repositories from creation inputs through the permanent API.
- [x] Cover the permanent API, migration compatibility, and authoring behavior.
- [x] Update related documentation and describe how to remove migration later.
- [x] Obtain the requested Claude Opus 5 follow-up review.
- [x] Run the repository gate, commit, and push the existing feature branch.

## Validation

- Focused unit and component checks passed, including 97 metadata component
  cases. Coverage includes an isolated module copy without migration files,
  local and GitHub missing-file warnings, invalid metadata, Bicep source
  comparison, root/deep-child scopes, and Bicep/Terraform migration conversion.
- Creation-focused checks passed after the review fixes: 8 unit and 51 component
  cases, including the compatibility inventory update and app-only preflight.
- The integrated gate reached all tests; its last two failures were old
  end-to-end step-count expectations. Updated both to include metadata and
  verify missing-file warnings without writes; all nine end-to-end cases pass.
- Final `.\build.ps1 pre-commit` passed: 1,301 unit tests, 8 existing skips, and
  all 345 component tests. The existing analyzer retry handled transient engine
  exceptions; the gate completed with zero errors.
- Package build passed with 24 functions and one alias, with no migration-only
  conversion/source-inference helpers in the module output.

## Review

- Opus reported no findings in the authoring/migration separation.
- Creation review found a disconnected authentication preflight and a
  comma-separated alias being emitted as one JSON alias. Restored the preflight
  after the dry-run gate and before publication, including app-only requests.
  Explicit aliases are now split, trimmed, and deduplicated for JSON without
  changing the inventory CSV cell.
- The original inventory update and app/publication controls are preserved.
  CSV data never supplies metadata initialization values.
- Opus confirmed both creation findings resolved with no regressions.
- Catalog module paths remain repository-relative, with `.` for Terraform
  roots; documentation and regression assertions make that convention explicit.

## Dependencies

The coordinated rollout and existing approval requirements remain unchanged.
This work does not run production workflows, merge remote changes, or change
repository permissions or workflow enablement.
