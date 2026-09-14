# Automatic metadata file creation

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Remove the intermediate files, approval flags, and repository registration that
currently block metadata backfill. Create missing `metadata.json` files directly
from existing indexes, module source, and the Bicep owner snapshot. Never
overwrite existing metadata or silently invent missing information.

The user then simplified Bicep delivery: add every missing metadata file directly
to the Bicep repository change and remove the Bicep workflow backfill path.
Terraform retains automatic file creation in its existing sync workflow,
including manual branch runs and strict dry runs.

Engineering-team review rules and Bicep metadata-only release exclusions are
separate repository changes. No live backfill, release, or permission change is
executed here.

## Checklist

- [x] Remove intermediate approval-file requirements and terminology.
- [x] Read existing metadata inputs automatically during Terraform sync.
- [x] Preserve every Bicep snapshot owner in the direct repository change.
- [x] Remove Bicep workflow backfill instead of adding another workflow path.
- [x] Cover create-only behavior, missing inputs, source rules, and dry runs.
- [x] Update documentation and prepare the validated changes for publication.

## Validation

- `.\build.ps1 pre-commit`: 1,232 unit tests passed, 8 skipped;
  249 component tests passed; no errors. Obsolete approval-file and Bicep
  automation tests were replaced with direct file-creation coverage.
- `.\build.ps1 build`: 24 public functions and the schemas packaged correctly.
- Existing files remain unchanged. Metadata mode bypasses Azure state/settings,
  unrelated formatting/managed files, and project-item updates.
- Corrected a CI failure caused by importing an installed module in the removed
  Bicep registration path; metadata creation loads the selected tools checkout.
- Actual Bicep data exposed and fixed one-item alternative-name arrays,
  one-character ARM child types, and existing underscore telemetry identifiers.
- The user approved empty owner lists and omitted telemetry prefixes for
  uninstrumented, unpublished Bicep children under BCPFR4. Existing Deprecated
  status and deployed telemetry identifiers are preserved.

## Dependencies

Separate changes remain outside this implementation:

- [Azure/bicep-registry-modules#7349](https://github.com/Azure/bicep-registry-modules/pull/7349):
  572 metadata files (222 roots, 350 children), metadata ownership, and release
  trigger exclusions. No existing Bicep source/compiled/version files changed.
- [#120](https://github.com/Azure/azure-verified-modules-tools/pull/120):
  engineering-only metadata review rules in generated CODEOWNERS; depends on
  the separate Terraform CODEOWNERS repair.
- [Azure/Azure-Verified-Modules#2929](https://github.com/Azure/Azure-Verified-Modules/pull/2929):
  the matching public workflow-template exclusion.

Pre-existing budget telemetry collisions and the Resource Graph legacy
identifier are recorded for normal future releases, not changed by backfill.
