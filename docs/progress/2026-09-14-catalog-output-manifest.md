# Catalog output manifest

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Make `repository-management/module-catalog/config.json` the authoritative
manifest for every catalog artifact, repository, bundle path, and publication
destination. Collection, generation, publication, and workflow configuration
must consume that definition rather than maintain independent filename lists.

Preserve legacy output paths by default, strict validation, exact publication
scope, stale-base protection, review-only publication, and disabled live rollout.

## Checklist

- [x] Define and validate the complete artifact manifest.
- [x] Wire all catalog stages and workflow repository selection to it.
- [x] Prove alternate configured paths propagate through the whole flow.
- [x] Cover invalid, duplicate, incomplete, and unsafe manifest entries.
- [x] Update documentation and prepare the validated slice for publication.

## Validation

- `.\build.ps1 pre-commit`: 1,232 unit tests passed, 8 skipped;
  307 component tests passed; no errors. Existing analyzer warnings remain
  non-blocking.
- Focused catalog suite: 85 tests passed, including a single-manifest
  collection/generation/publication run with renamed CSV/catalog/control files,
  alternate repository names, and different destination directories.
- Workflow checkout and publication-token repository choices come from validated
  manifest outputs. The separate trusted workflow-repository/main guard remains.
- Publication rejects a bundle whose manifest hash no longer matches the
  trusted checkout. Artifact path literals are absent from the catalog scripts.

## Blockers or dependencies

No production collector or publisher is run during this refactor.
