# Module metadata foundation

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Implement the foundation for the shared Bicep and Terraform module-metadata rollout. This repository
owns the versioned input/output schemas, validation and initialization tooling,
and the dual-source catalog synchronization workflow. Module-owned
`metadata.json` takes precedence; legacy catalog rows remain during migration.

The one-off backfill is opt-in, preserves existing metadata, and requires
reviewed values where a child's identity cannot be derived safely. No production
workflow, fleet backfill, registry publication, or cutover runs in this slice.
The forthcoming Bicep sync can consume the same initialization interface.

The 2026-09-10 Bicep owner-team snapshot is an additional one-off backfill
input. It contains 240 complete team records, including 12 teams with more than
two members (maximum four). Merge every member/maintainer GitHub handle with the
legacy owner slots, deduplicate case-insensitively, and retain the full list on
root metadata. Children inherit that list. Do not commit the original snapshot
or its personal-name fields.

## Checklist

- [x] Read the proposal, repository contracts, and current sync implementation.
- [x] Add the centrally packaged v1 metadata and catalog schemas.
- [x] Implement shared validation and non-overwriting initialization.
- [x] Add the dual-source catalog generator and workflow in this repository.
- [x] Provide an opt-in, reviewable backfill path for both ecosystems.
- [x] Cover schema, inheritance, compatibility, and failure behavior.
- [x] Update directly related documentation and record rollout dependencies.
- [x] Run the repository gate and prepare the feature branch for review.

## Validation

- `.\build.ps1 pre-commit`: 1,108 unit tests passed, 8 platform-specific
  cases skipped; 224 component tests passed; zero errors. Existing analyzer
  warnings remain non-blocking. Coverage includes both schema shapes, unlimited
  owner arrays, exact telemetry limits, strict JSON/UTF-8, inheritance,
  compatibility, complete-batch preflight, publication boundaries, and `-WhatIf`.
- Native integration run: 2 passed. Bicep 0.46.1 compiles the scoped reader and
  produces byte-identical ARM after owner/tier/canonical-only edits. Terraform
  1.15.8 evaluates root metadata and child tier inheritance in a provider-free
  plan with no resource changes.
- `.\build.ps1 build`: staged 24 public functions and both versioned schemas.
- The shipped snapshot reader imported the supplied capture read-only:
  240 teams, 280 memberships, 12 teams above two members, maximum four.
  Its projection retains no personal-name or database-ID fields.
- Catalog regressions cover real Bicep helper-folder conventions, UTC
  publication months, provider variants, all owner handles, and orphaned status.

## Blockers or dependencies

- Production rollout and the 60-day per-ecosystem cutover require operator
  approval; no existing manual source is deleted in this slice.
- Terraform telemetry transport is a separate change. This slice supplies its
  metadata source, not a replacement for the transport. Source wiring remains
  opt-in: the initial Bicep rewrite can change the compiled template, and
  Terraform readers need the transport consumer before strict unused-local
  checks can accept them.
- Bicep fleet delivery depends on the forthcoming Bicep sync.
- Release Avm.Authoring with the new metadata API before enabling repository
  backfill. Review complete seed manifests before registering any repository;
  the checked-in seed map remains empty.
- Delivery into the Bicep common static suite and Terraform managed validation
  files remains upstream rollout work. The shared validator and source-literal
  checks are available here, but no upstream module repository is changed.
- Scheduled catalog collection remains disabled until explicitly enabled.
  The live fleet collector and cross-repository publication have not been run.
- Team technical documentation should be updated in Azure-Verified-Modules-Docs
  with the new workflow and rollout procedure.
