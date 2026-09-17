# Temporary module metadata migration

Create missing `metadata.json` files from the existing module indexes and source.
Existing files are validated and left unchanged. There are no intermediate
approval files, approval flags, or repository-registration lists.

This directory is disposable after the one-off migration and reconciliation.
It owns CSV conversion, source inference, owner-snapshot processing, and the
backfill adapter. None of that code is packaged in Avm.Authoring.
The permanent module only reads existing metadata, validates files or supplied
values, and initializes files from supplied values.

## Terraform repository sync

Use the existing Terraform sync workflow with `metadata_backfill: true` and a
repository filter such as `avm-ptn-example-repo`. This is **full normal repository
sync**, not a metadata-only operation. `plan_only: true` runs normal planning and
prepares files in a disposable checkout without publishing them.
Workflow backfill requires `workflow_dispatch` and `metadata_backfill: true`.
Scheduled and `repository_dispatch` runs cannot activate it; the runtime adapter
also rejects non-manual events. The local command below remains an explicit
operator action, not an automatic workflow trigger.

The sync reads the matching canonical public CSV at one commit, never a `test-`
catalog preview. If a repository
has no public row yet, its entry in the tools repository's existing
`repository-metadata.csv` is used. Descriptions can also come from `_header.md`.
Missing information is reported rather than invented.

Explicit canonical overrides take precedence over the index's `CanonicalType`,
then lossless inference. For Terraform patterns/utilities, a single alphanumeric
suffix is retained (`avm-utl-naming` becomes `naming`); the existing two-component
mapping is unchanged (`avm-utl-types-common` becomes `types/common`). Longer,
ambiguous hyphenated names still require an explicit canonical value. Resource
ARM types and grouped Bicep paths retain their existing requirements.
Telemetry-free utilities remain telemetry-free.

One conditional call in ordinary checkout preparation invokes
`MetadataBackfillSync.ps1` before pre-commit. That temporary script collects CSV
context and starts `Invoke-ModuleMetadataBackfillWorker.ps1` through the existing
repository process transport. Request/result files stay outside the target
checkout and are removed afterward. The worker imports metadata APIs from the
selected tools checkout without changing the caller's module discovery.
Ordinary sync still installs and uses the normal released Avm.Authoring module,
including its existing version/upgrade checks. Single-segment canonical values
require a compatible released schema for normal pre-commit validation; worker
success alone does not establish full-sync compatibility.

Normal managed files, formatting, CODEOWNERS, repository/Azure management,
state setup, tenant gates and selected project synchronization all still run.
Apply uses the unchanged shared publisher: timestamped pre-commit branch,
standard commit/title/body and `[skip ci]`, followed by the existing authorized
App merge with exact-head matching. It is not a review-only operation. Existing
open work is handled by the ordinary sync controls, not a separate metadata
branch or deferral rule. No new permission or bypass is granted.

Metadata/script failure stops pre-commit and file publication; it does not undo
management changes already applied earlier in normal sync. Every production
run requires operator approval for that full scope.

The Terraform `metadata_update_source` option is removed. Neither initialization
nor backfill creates `main.metadata.tf`, and Terraform `-UpdateSource` fails
before writes. Existing authored `.tf` files are not removed or rewritten by
metadata creation. Future telemetry wiring belongs in MaPoTF.

## Local use

Load the module from the tools checkout, then run against a disposable module
checkout and existing CSV data:

```powershell
Import-Module .\src\Avm.Authoring\Avm.Authoring.psd1 -Force
.\repository-management\module-metadata\Invoke-ModuleMetadataBackfill.ps1 `
    -RepositoryRoot C:\work\terraform-azurerm-avm-ptn-example-repo `
    -Repository Azure/terraform-azurerm-avm-ptn-example-repo `
    -Ecosystem terraform `
    -LegacyCsvPath C:\data\TerraformPatternModules.csv `
    -WhatIf
```

The code checks every discovered module before writing files. A disabled module,
missing required data, invalid metadata, path traversal, or caller-controlled
linked path stops the operation. Only the genuine macOS system temporary aliases
are verified and resolved; the resulting physical path is validated again.
Removing `-WhatIf` writes only missing files.
This local script creates files only; repository publication and management
belong to the normal sync workflow above.

## Bicep

Bicep metadata files are added directly to the `bicep-registry-modules` change,
not through the Bicep Sync workflow. That workflow continues to manage CODEOWNERS.

`Get-AvmMetadataBackfillCandidate` in this directory derives migration values;
it uses the permanent validation and initialization commands before any write.
Its Bicep source reader reuses the packaged Bicep literal/comment parsers, which
remain necessary for ordinary source validation. The archived owner-team reader
retains every member and maintainer handle; it does not copy personal names or
invent replacement owners.

Unowned modules may have an empty owner list. Catalog output reports them as
Orphaned unless the existing index already marks them Deprecated, which is
preserved. Unpublished Bicep children without their own telemetry omit
`telemetryIdPrefix`, as allowed by [BCPFR4](https://azure.github.io/Azure-Verified-Modules/spec/BCPFR4).
Roots, independently published children, and instrumented modules still require
the field. Existing telemetry identifiers are preserved rather than repaired
during metadata-file creation.
Bicep alone still supports optional `-UpdateSource` telemetry-prefix wiring.

## Removing migration after reconciliation

Delete this directory and the migration-specific tests
`MetadataBackfill.Component.Tests.ps1` and `MetadataBackfill.RepositorySync.Tests.ps1`.
Remove the `metadata_backfill` input and its forwarding from the Terraform
sync workflow, plus the conditional hook in
`repository-sync/scripts/Invoke-RepositorySync.ps1`,
`repository-sync/scripts/lib/AvmPreCommit.ps1`, and input guards in
`repository-sync/scripts/Test-RepositorySyncInputs.ps1`.
Keep the shared repository-file publisher and ordinary sync setup unchanged.

Keep Avm.Authoring's metadata commands and schemas, normal authoring validation,
new-repository initialization, and the permanent module-catalog workflow.
Neither Avm.Authoring nor new-repository initialization imports this directory.
