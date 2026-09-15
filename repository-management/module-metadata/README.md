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
repository filter such as `avm-ptn-example-repo`. `plan_only: true` remains a
strict dry run. The workflow loads the metadata commands from its selected tools
checkout, so a manual branch run can use the new code without a Gallery release.

The sync reads the matching public module index at one commit. If a repository
has no public row yet, its entry in the tools repository's existing
`repository-metadata.csv` is used. Descriptions can also come from `_header.md`.
Missing information is reported rather than invented.

The metadata operation does not run unrelated formatters or managed-file
updates. It uses a disposable checkout and the shared repository-file publisher.
Apply opens a reviewable change with CI enabled; it never auto-merges. An existing
metadata change or branch is left alone. Normal Terraform sync behavior remains
unchanged when metadata backfill is not selected.

`metadata_update_source` is a separate, explicit option for adding native JSON
readers alongside newly created metadata. It is off by default and never rewrites
an existing metadata file.

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
missing required data, invalid metadata, path traversal, or linked path stops
the operation. Removing `-WhatIf` writes only missing files.

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

## Removing migration after reconciliation

Delete this directory and the migration-specific tests
`MetadataBackfill.Component.Tests.ps1` and `MetadataBackfill.RepositorySync.Tests.ps1`.
Remove the `metadata_backfill` / `metadata_update_source` inputs and conditional
branches from the Terraform sync workflow, plus their hooks in
`repository-sync/scripts/Invoke-RepositorySync.ps1`,
`repository-sync/scripts/lib/AvmPreCommit.ps1`, and input guards in
`repository-sync/scripts/Test-RepositorySyncInputs.ps1`.

Keep Avm.Authoring's metadata commands and schemas, normal authoring validation,
new-repository initialization, and the permanent module-catalog workflow.
Neither Avm.Authoring nor new-repository initialization imports this directory.
