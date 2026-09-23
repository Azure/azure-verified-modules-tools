# Module catalog sync

The tools repository owns both v1 schemas and the four-hourly workflow. Public outputs
belong in `Azure/Azure-Verified-Modules/docs/static/module-indexes`, not the
internal team documentation repository.

The six generated CSVs replace the canonical files, for example
`BicepResourceModules.csv`. These files are both source inputs and publication
targets. The JSON catalog uses `v1/modules.json`; existing `test-` files are
neither updated nor deleted by this workflow.

[`config.json`](config.json) is the complete artifact manifest. `repositories`
selects the docs, Bicep source, and tools repositories; `destinations` supplies
the repository-relative output directories. Each `outputs` entry declares its
kind, relative filename, and destination. CSV entries also declare `sourceFile`,
the canonical input name; `file` is the matching output name. This includes all six CSVs,
`BicepMARModules.json`, and `v1/modules.json`.
The `migration-report` and `publication-plan` entries have null destinations:
they remain in the `module-metadata-catalog` workflow artifact and are never
published to the repository. The plan is emitted when publication-base
information is available.

Collection, generation, workflow checkouts/token targets, and publication use
the same validated manifest. Unsafe paths,
duplicates, unknown fields, missing artifact kinds, and ambiguous CSV mappings
fail before output is written. Publication binds the bundle to the manifest
hash, so changing the manifest requires a fresh collection. The workflow's own
trusted-repository/main guard remains a separate security boundary.

`module-metadata-sync.yml` runs at `33 1-23/4 * * *`: 01:33, 05:33, 09:33,
13:33, 17:33, and 21:33 UTC daily. These starts are one hour after Terraform
sync and one hour before Bicep sync on their scheduled days. Runtime overlaps
remain possible; the existing concurrency group prevents simultaneous catalog runs.
Manual runs default to artifacts only. Publication requires `main`, the protected
`avm` environment, and an explicit non-plan run or the four-hour schedule.
Scheduled runs publish and merge; the manual `plan_only` default does not apply.
Disable the workflow when its scheduled publication must stop; enabling it also
allows scheduled publication, not just manual previews. The existing app needs
read access for collection, organization members read for owner-team validation,
and contents/pull-requests write restricted to the public docs repository
for publication. Nothing applies repository settings or cloud state.
This workflow never creates module `metadata.json` files.

## Offline generation

```powershell
.\repository-management\module-catalog\scripts\Invoke-ModuleCatalog.ps1 `
    -InputPath .\snapshot -OutputPath .\out\catalog
```

Use a new output directory. The snapshot contains `legacy/` (all six CSVs and the
approved `BicepMARModules.json` mirror), `sources/bicep/`, source-bearing
`sources/terraform/terraform-{azurerm,azapi,azure}-avm-*/` repositories,
`registry.json`, `github.json`, and `revisions.json`. Repository revisions include
the boolean GitHub `archived` flag for every available Terraform repository.
Bicep snapshots preserve each module's `DEPRECATED.md` alongside its source.
`Get-ModuleCatalogSnapshot.ps1` collects these read-only; `GH_TOKEN` is its
authentication boundary. Only trusted local code is imported. Fetched module
files are data, never scripts, builds, Terraform plans, or Bicep compilations.
The standalone API client handles live JSON data rather than executable tool
downloads, whose separate module helper requires a pinned SHA256.

Local collection/generation can use `-ConfigurationPath` for a reviewed manifest
variant. Publication always reads the trusted tools-checkout manifest, never a
configuration supplied inside the generated bundle.

Only valid module metadata creates catalog entries and eligible CSV rows. There are no
ecosystem mode options or full legacy-record fallback. Present metadata must pass
the packaged validator; catalog collection does not enforce parity with Bicep source
literals. Reduced children require family-root
metadata and inherit owners. The JSON catalog also includes the
family's alternative names and comments; child CSV cells for those two fields
stay unchanged, including blanks. Newly discovered child rows leave them blank.

The six CSVs retain their existing column order and matched-row compatibility
fields; `CanonicalType` is not added. Missing metadata is reported but never
reconstructed from a CSV. Existing source rows without metadata-backed replacements
hold back affected outputs by default. Only existing columns are projected for metadata rows; full
owners and child identity remain available in `v1/modules.json`. Its canonical
keys contain arrays per ecosystem: repository plus module path distinguishes
provider variants. The artifact's `v1/migration-report.json` records missing metadata, unresolved
source identities, source-row snapshots, removals, and cross-ecosystem parity.
Each catalog owner is an object with `handle`, `type`, and `displayName`.
`type` is `user` for a GitHub username and `team` for a qualified handle such
as `@Azure/avm-core-modules`. User display names come from the GitHub profile
`name`; team display names come from the GitHub team `description`. Either may
be null when GitHub does not supply or expose the value. Authored
`metadata.json` files continue to store owner handles as strings.
Canonical types come from metadata, not inferred CSV taxonomy.
Resources use case-sensitive `Microsoft.*` or `Oracle.Database` ARM types.
For `Oracle.Database/cloudVmClusters`, `providerNamespace` is `Oracle.Database`
and `resourceType` is `cloudVmClusters`; Terraform's `provider` remains separate.
Pattern and utility canonical keys may be single names such as `naming` or
slash-separated paths. Their ARM-only `providerNamespace` and `resourceType`
fields remain null; module paths and parent identities are unchanged.

Exact lowercase `canonicalType: "helper"` is reserved for child modules in both
ecosystems and all three family kinds. JSON retains every helper under the
`helper` key, distinguished by repository and module path, with inherited owners,
the derived family `moduleType`, and null `providerNamespace`/`resourceType`.
Helpers are not ARM resource types. All six CSV outputs omit helpers, in both
preview and canonical modes. A helper previously present in a source CSV still requires the normal removal
override unless it qualifies for the deprecated/unpublished exclusion below.

### Deprecated, unpublished modules

Metadata-backed modules that are both deprecated and registry `not-published`
are omitted from CSV indexes and `v1/modules.json`. Each warning names the
repository and module path and recommends deleting unused source, or an unused
Terraform repository if it contains no published modules. No source is deleted.
Published deprecated modules and published descendants remain indexed.
The separate approved MAR registration mirror is unchanged.

The hashed migration report retains validated records in `excludedModules`
and an `excludedEntries` count. Only these exact repository/module identities
are exempt from removal holds, at both generation and publication; they do not
require `Force`. Invalid metadata, incomplete registry/archive evidence, and
unrelated removals retain their safeguards.

### Source CSV row-removal override

Every source CSV row is checked against the generated module implementation
identities. New rows cannot hide removed rows by keeping the total count unchanged,
and Terraform repositories for different providers remain distinct even when
their module names match. The baseline is `sourceFile`, which also names the
publication destination. Existing preview files do not affect this check.

Use `-Force` on `Invoke-ModuleCatalog.ps1` only when the other listed source-row
removals are intentional. The diagnostics identify each source file, module name,
and repository URL. A forced result records `sourceCsvRows`, `csvRowRemovals`
(`sourceFile`, `moduleName`, `repoURL`), and `csvRowRemovalsForced` in
`v1/migration-report.json`. It does not recreate missing metadata or legacy rows.

The manual workflow input `force` defaults to `false`; schedules cannot select
the override. `plan_only=true` with `force=true` can produce a review artifact
without publication. For local bundle validation or publication,
`Publish-ModuleCatalog.ps1` also requires explicit `-Force` for these other removals;
the generation flag in an artifact does not grant publication permission.
The publisher rechecks the report against the actual source CSVs on the unchanged
main-branch base before any file writes.

Manual `plan_only=true` runs render a per-CSV summary table and, for each
changed file, a field-level breakdown of which columns actually changed
(added/removed rows plus a `Field | Before | After` table), so reviewers are
not shown the full rewritten row for a one-column change. The complete
unified line diff is still available, nested in a collapsed "Raw line diff"
section. Download the `module-metadata-csv-diff` artifact for the
authoritative `all-csv.diff`, individual patches (including per-file
`.fields.md` field breakdowns), and exact `before/` and `after/` CSVs.

Force does not bypass invalid metadata, incomplete snapshots, altered hashes,
stale bases, output allow-lists, `WhatIf`, or publication approvals. It never
enables a Git force-push.

`modulePath` is relative to the implementation's repository root, using `/`
separators. Bicep paths include `avm/res/...`, `avm/ptn/...`, or `avm/utl/...`;
Terraform roots use `.`, and submodules use `modules/{name}`.
`parentModule` and `familyModule` use the same repository-relative basis.
These paths are derived from file locations, not stored in module metadata.

Registry errors, rate limiting, authentication failures, truncated GitHub
discovery, and incomplete output data stop generation. Registry 404s mean
not-published only at the module lookup boundary; a missing listed release is an
error. First-published months use the earliest actual release timestamp, not the
lowest version number. Terraform child availability/dates come from releases
containing that submodule; per-child download counts are unavailable and remain
null. The approved MAR string-array mirror is preserved, not replaced with an
MCR-only list that would lose approved but unpublished modules.

`owners` is a flat list of usernames and qualified team handles. CSV user columns
project the first two usernames, and the existing team column projects the
first team; JSON retains all entries. Teams are never placed in user columns.
Tier metadata and repository-configuration publication are not implemented.

For nondeprecated modules, registry `not-published` means Proposed, even when
source files exist and `owners` is empty. Published modules without owners are
Orphaned; published modules with owners are Available. Both CSV and JSON outputs
use this rule rather than preserving prior Proposed or Orphaned status.

Deprecation takes precedence over ownership. A Bicep
`DEPRECATED.md` marks that module and its descendants; a child's marker does not
deprecate its parent or siblings. An archived Terraform repository marks every
module in it deprecated. Prior CSV Deprecated state also marks matching
metadata-backed entries as deprecated; only published entries remain indexed.
A row without metadata is subject to the removal guard,
not retained as a legacy record. Missing or malformed archive
evidence fails generation rather than being treated as an active repository.
Old snapshots without that evidence must be collected again. The workflow only
reads these signals; it does not archive repositories or perform retirement steps.

Publication checks output hashes, exact allowed paths, schema, unchanged input
and output-base hashes on current `main`.
Canonical CSV hashes protect both the source inputs and publication destinations.
Existing app-owned branches are updated without force; human commits or unrelated
branch changes stop publication. Publication squash-merges through the existing
AVM App (`--admin --match-head-commit`) and verifies the merged head. Merge failures
fail the job; a retry also merges an unchanged pending candidate.
Report changes left by earlier catalog runs are restored to the current main
version (or removed from the candidate if absent on main) before merging.
No direct `main` push, permission edit, or obsolete-source deletion is used.

Terraform metadata creation, the direct Bicep metadata file change, Terraform telemetry transport,
refreshing the private-source MAR mirror, and approval of any source-row removals
remain rollout dependencies. Update the internal Azure-Verified-Modules-Docs
team catalog how-to with the exclusion warnings and deletion recommendation;
generated catalogs do not belong there.
Follow the [metadata rollout plan](../../docs/metadata-rollout.md) for merge
order, required workflow pauses, and the first module/catalog runs.

The canonical CSV cutover requires a fresh snapshot because the manifest changed;
bundles collected for `test-` destinations cannot be published with this manifest.
Source CSV collection and row-retention checks are permanent safeguards
independent of metadata migration tooling.
