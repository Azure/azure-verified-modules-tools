# Metadata source CSV retention

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Remove dual-source catalog generation and its ecosystem mode options. Generate
catalog entries and CSV rows only for valid module metadata. By default, fail
when an existing source CSV row would disappear; an explicit `Force` override
may permit those removals without weakening other validation or publication
controls.

The user explicitly chose the source CSV as the comparison baseline, not an
existing `test-` preview. The same protection must work when a later reviewed
configuration change makes the output overwrite the source CSV.

## Contract

- Compare module implementation identities per source CSV, not just row counts
  or module names shared by different Terraform providers.
- Report missing metadata and removed source rows. Never recreate a full
  catalog record from legacy CSV metadata.
- Preserve matched-row compatibility fields, including child aliases/comments
  and their blank cells, and prior Deprecated status for metadata-backed entries.
- Keep source-derived Bicep/Terraform deprecation, profile/registry checks,
  invalid-metadata failures, and family ownership validation unchanged.
- Validate source-row evidence before publication and recheck the actual
  immutable source CSVs before writing files. Force permits only row removals.
- Keep preview destinations, manual backfill isolation, ordinary authoring's
  missing-file warnings, two-team metadata review, and BAMI controls unchanged.

## Checklist

- [x] Resolve and publish the latest-main merge as a separate change.
- [x] Confirm source-only CSV comparison with the user.
- [x] Remove mode options and legacy-record generation.
- [x] Add source-row removal protection and the explicit force path.
- [x] Cover generation, publication, workflow, and compatibility regressions.
- [x] Update current operational and public process documentation.
- [x] Pass the local gate and the requested Opus follow-up.
- [x] Prepare the verified slice for publication in the existing tools review.

## Validation

- The full offline `.\build.ps1 pre-commit` gate passed: 1,513 unit tests,
  eight existing skips, and 493 component tests. Persisted NUnit reports record
  zero errors, failures, invalid cases, or unexecuted tests.
- The initial focused catalog run passed 139 cases and exposed one Pester
  assertion that directly piped a deliberately non-enumerated empty array.
  Capturing that array before asserting fixed the test; production logic did not
  change. All 25 publication/workflow cases then passed, followed by the full gate.
- Coverage includes equal-count replacements, Terraform provider variants sharing
  names, unresolved proposals, source-only rather than preview comparison, future
  canonical overwrite, explicit force at generation and publication, tampered
  evidence, unchanged source hashes, and preservation of matched metadata fields.
- The workflow has one default-false manual `force` input, passed through the
  environment to generation, publication validation, and publication. Schedules
  cannot select it. Existing token scopes, main/environment checks, and
  non-force Git publication are unchanged.
- The migration report records `sourceCsvRows`, `csvRowRemovals` with
  `sourceFile`/`moduleName`/`repoURL`, and `csvRowRemovalsForced`.
- The requested narrow Opus review found no issues. Offline probes confirmed
  identity-aware removals, duplicate rejection, evidence round-trips, publication
  ordering, and force boundaries without changing the implementation.
- Intermediate merge-head hosted CI passed after one targeted retry of an
  unchanged Windows metadata source-check case. The case also passed locally in
  isolation and with all 117 metadata component cases. No cause was confirmed,
  and no assertion or runtime behavior was weakened.
- The public process draft is updated at
  `ef15455cf14a7f514e40d7615e5f78e9bdec2b7a`, with seven reported hosted checks
  passing; its final executable-contract verification gate remains pending.

## Dependencies

Builds on the history-preserving merge
`cd9b321322fe1d4ce01d8de927ae362c43e5a68f` of main
`25f1f4b2ca24505f9e1888542172322a6be6bc4a`.
The main merge preserved incoming MAPOTF 0.2.1/provider-alias work and passed
the full local gate plus 33 targeted native integration cases.

Continue in [#113](https://github.com/Azure/azure-verified-modules-tools/pull/113).
Record the published head and fresh final-head hosted results in that review.
The public process draft remains gated on the final executable contract and
adoption approval. No source CSV row is being removed from a live repository,
and no production workflow, permission change, or remote main merge is authorized.
