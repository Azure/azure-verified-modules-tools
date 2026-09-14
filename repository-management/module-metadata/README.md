# One-off module metadata backfill

These opt-in adapters prepare and apply metadata to **existing local checkouts**.
They never clone, publish, query Azure/GitHub, install dependencies, or change
legacy CSVs. Keep both sources during the 60-day per-ecosystem migration.
`reviewed-seeds.json` is deliberately empty: no repository is enabled by default.

Load an Avm.Authoring release exporting `New-AvmModuleMetadataSeed`,
`Initialize-AvmModuleMetadata`, and `Test-AvmModuleMetadata`. All schema validation
uses that release's packaged schema; no remote schema or mutable module code is
fetched. The sync workflow fails its capability check until this API is released.

## Prepare and review

```powershell
$checkout = 'C:\work\terraform-azurerm-avm-res-storage-account'
$repository = 'Azure/terraform-azurerm-avm-res-storage-account'
$parameters = @{
    RepositoryRoot = $checkout
    Repository = $repository
    Ecosystem = 'terraform'
    LegacyCsvPath = @('.\repository-management\repository-sync\config\repository-metadata.csv')
}
$report = .\repository-management\module-metadata\New-ModuleMetadataBackfillSeed.ps1 @parameters
$report.Modules | Select-Object path, status, issues
```

`Status: fail` returns **no usable manifest** and reports every discovered module,
including unresolved children. Supply reviewed overrides, then rerun with
`-OutputPath C:\review\storage-seeds.json`. Output must be outside the module
checkout and must not already exist. `-WhatIf` does not write the output.
No module files are written during preparation.

For Bicep, pass `-Ecosystem bicep`, its explicit `owner/repository`, and any of
the three legacy Bicep index CSVs in `-LegacyCsvPath`. Discovery includes every
`main.bicep` under `avm/res`, `avm/ptn`, and `avm/utl`, including nested children.
Terraform discovery includes the root and immediate source-bearing `modules/*`.
Examples, tests, hidden directories, build artifacts, and Bicep internal
`modules/` helpers are excluded. A child must have a discovered family root.

Preparation preserves Bicep name/description literals and existing readable
telemetry prefixes. Resource identities use explicit legacy provider namespace
and resource-type columns; a Bicep child may use one unambiguous non-existing
ARM resource declaration. Bicep pattern/utility taxonomy comes from its path.
Terraform kebab names are **not** split into guessed taxonomy. Root Terraform
prefixes may be proposed from the logical repository ID, never truncated.

Terraform descriptions use an existing `ModuleDescription` column or the sole
plain prose paragraph of `_header.md`. Ambiguous descriptions, child identities,
and unreadable telemetry require overrides. Alternative-name CSV cells retain
their established comma-separated interpretation. Initial tier is `maintained`.
Only GitHub handles/team identifiers are copied from ownership columns.

`-OverridePath` accepts this partial, reviewed mapping (omit entries not needed):

```json
{
  "schemaVersion": 1,
  "repository": "Azure/terraform-azurerm-avm-res-storage-account",
  "ecosystem": "terraform",
  "reviewed": true,
  "modules": [
    {
      "path": "modules/blob-service",
      "updateSource": false,
      "metadata": {
        "moduleDisplayName": "Blob Service",
        "moduleDescription": "Deploys a Blob Service.",
        "canonicalType": "Microsoft.Storage/storageAccounts/blobServices",
        "telemetryIdPrefix": "46d3xtrf.res.storage-blobservice"
      }
    }
  ]
}
```

Instead of `metadata.moduleDescription`, a Terraform override can specify
`"descriptionSource": {"path": "_header.md", "paragraph": 2}`. Paragraphs are
one-based blank-line-separated blocks, including headings in the numbering.
The selected block must be plain prose and is copied without rewriting.

`-OwnerMappingPath` accepts a reviewed, handle-only ownership snapshot:

```json
{
  "schemaVersion": 1,
  "repository": "Azure/bicep-registry-modules",
  "reviewed": true,
  "modules": [
    {
      "path": "avm/res/storage/storage-account",
      "githubHandles": ["first-owner", "second-owner", "third-owner"]
    }
  ]
}
```

Use exact discovered root paths and actual reviewed handles. Merge every member
and maintainer from the source snapshot, not just two slots. Handles are
deduplicated case-insensitively with legacy and override handles. Do not check in
the original ownership snapshot or its personal-name fields. Children carry no
owners, tier, alternatives, or comments.

For the deleted Bicep module-owner teams, pass the original local capture directly
to preparation with `-BicepOwnerSnapshotPath C:\review\owners-bicep-team-snapshot-2026-09-10.json`.
The capture must contain complete, matching reported/retrieved/team counts and
complete member edges (`totalCount` matches; `hasNextPage` is false). Both MEMBER
and MAINTAINER logins are included, without an owner limit. Legacy primary and
secondary handles retain their first positions; additional handles are deduplicated
case-insensitively. No personal names, database IDs, or raw snapshot objects
are written to metadata or the preparation report.

Matching uses the exact legacy `ModuleOwnersGHTeam` slug first. Only a unique
root-path fallback is accepted: remove hyphens within the group/name segments
and form `avm-kind-group-name-module-owners-bicep`. Ambiguous or unmatched snapshot
teams make preparation fail with diagnostics in `OwnerSnapshot`; no partial
manifest is written. Root `ownerSnapshot` reports show the match method and any
stale legacy references. Deleted per-module team references are not carried into
new `owners.team` values; nondeleted shared teams remain supported.

Existing metadata is never enriched in place. Its report explicitly says
`skipped-existing-metadata` and lists missing snapshot handles for manual review.
Children only inherit their root's ownership. Keep the full snapshot outside
this repository; only reviewed generated seeds belong under `seeds/`.

## Apply to a checkout

The generated manifest includes `schemaVersion`, `repository`, `ecosystem`,
`reviewed: false`, and the complete `modules` array. Each module contains `path`,
`moduleType`, `parentPath` (null for roots), `updateSource`, and full `metadata`.
Review all values, then set the manifest's `reviewed` to `true`.

```powershell
.\repository-management\module-metadata\Invoke-ModuleMetadataBackfill.ps1 `
    -RepositoryRoot $checkout -Repository $repository `
    -SeedManifestPath C:\review\storage-seeds.json -WhatIf
```

Remove `-WhatIf` only after reviewing the plan. Every intended seed, existing
metadata file, parent relationship, and requested source change is preflighted
before writing any module file. Missing children, unsupported paths, absolute
target paths, traversal, casing collisions, and reparse points fail closed.
Existing metadata is validated and never overwritten, even if a seed changes.
Run with exclusive access to the checkout; filesystem errors during application
are reported, not hidden or rolled back.

Source readers need **both** `-UpdateSource` and `updateSource: true` on the
reviewed entry. Bicep uses the core initializer's scoped JSON telemetry reader;
literals remain unchanged. Terraform adds `main.metadata.tf`, including root
tier inheritance for children, **not** `metadata.tf.json` or a telemetry transport
replacement. Keep Terraform source wiring disabled until the transport consumes
the locals; otherwise unused-local checks may fail.

## Repository sync opt-in

Check a reviewed Terraform manifest into `seeds/` and register its exact
`owner/repository` in `reviewed-seeds.json`, for example a value of
`repository-management/module-metadata/seeds/storage-seeds.json`.
The empty map intentionally fails when an unregistered repository opts in.

Only manual `repository-management-sync.yml` dispatches can enable
`metadata_backfill`. Start with `plan_only: true`; `metadata_update_source` is
separate and defaults to false. Scheduled and repository-dispatch events cannot
activate either operation. Seed paths come from the checked-out tools map, not
user-supplied expressions or network downloads.

Backfill runs on the sync's temporary target checkout before ordinary pre-commit.
Its stable `avm-bot/module-metadata-backfill` branch keeps CI enabled and is never
auto-merged. An existing open review or existing branch is deferred rather than
force-updated. Plan mode never commits, pushes, or opens a review. Normal sync
behavior remains unchanged with backfill disabled. The forthcoming Bicep sync can
call the same local application script; no Bicep fleet trigger is added here.
