# Repository creation

[`scripts/New-Repository.ps1`](scripts/New-Repository.ps1) is the operator-driven
Terraform repository creation entry point. It initializes `metadata.json`
through `Initialize-AvmModuleMetadata` before publishing the repository's first
commit. The existing tooling-repository CSV inventory update and its pull
request are preserved as a separate compatibility step. That step reads the
index only to append, sort, and publish it; it never supplies metadata.json values.
Creation does not run metadata backfill.

Run from a trusted checkout of this tools repository using PowerShell 7.4+.
Creation imports `src/Avm.Authoring/Avm.Authoring.psd1` directly, not an installed
Gallery version. It does not install or update Avm.Authoring. Applying requires
authenticated `gh`, Git push access, and a configured Git commit identity. The optional app
installation request retains its existing `powershell-yaml` installation step.
Existing open-source portal setup prompts still run after publication.

## Explicit inputs

```pwsh
$request = @{
    moduleName = 'avm-res-storage-storageaccount'
    moduleDisplayName = 'Azure Storage Account'
    moduleDescription = 'Deploys an Azure Storage account.'
    resourceProviderNamespace = 'Microsoft.Storage'
    resourceType = 'storageAccounts'
    tier = 'maintained'
    telemetryIdPrefix = '46d3xtrf.res.storage-storageaccount'
    ownerPrimaryGitHubHandle = 'first-owner'
    ownerPrimaryDisplayName = 'First Owner'
    ownerSecondaryGitHubHandle = 'second-owner'
    ownerSecondaryDisplayName = 'Second Owner'
    ownerGitHubHandles = @('third-owner')
    ownerTeam = '@Azure/storage-owners'
}

# Validate the supplied values and show the plan without filesystem or GitHub writes.
.\repository-management\repository-creation\scripts\New-Repository.ps1 @request -PlanOnly

# After reviewing the plan, omit -PlanOnly to create and publish.
```

The values above are illustrative: supply the requested module's actual
description, canonical type, tier, telemetry identifier, and owners.

| Metadata field | Creation input |
| --- | --- |
| `$schema` | `$id` of the schema packaged in the checked-out module |
| `schemaVersion` | `1` |
| `moduleDisplayName` | `moduleDisplayName` |
| `moduleDescription` | Required `moduleDescription`; never copied from a display name |
| `canonicalType` | Required `canonicalType`; resource modules may instead supply both `resourceProviderNamespace` and `resourceType` |
| `tier` | Required `tier`, either `core` or `maintained` |
| `telemetryIdPrefix` | Explicit `telemetryIdPrefix`, required for resource and pattern roots |
| `owners.individuals` | All supplied primary/secondary legacy handles followed by `ownerGitHubHandles` |
| `owners.team` | Optional `ownerTeam` |
| `alternativeNames` | Comma-separated `moduleAlternativeNames`, trimmed with empty and duplicate entries removed |

No owner is inferred. An empty owner array is valid; there is no two-owner
limit. Handles must satisfy the schema, without a leading `@` for individuals.
Legacy owner display names are inventory fields, not metadata.json fields.
The compatibility inventory retains its required primary owner handle/display
name and, for resource modules, resource provider namespace/type inputs. When
inventory publication is skipped, these CSV-only requirements do not prevent
metadata initialization with an explicitly empty owner list.
Pattern and utility canonical taxonomy paths must be supplied explicitly;
creation never guesses them from a repository name. Conflicting resource
namespace/type and canonical type inputs fail visibly.

`moduleAlternativeNames` retains its original string parameter type and is
published unchanged in the CSV cell. Only the explicit creation argument is
split into metadata aliases; the CSV is never read to supply them.

The module kind comes from `avm-res-`, `avm-ptn-`, or `avm-utl-`; the ecosystem is
Terraform. Creation does not initialize child modules.

## Plan, publication, and recovery

`-PlanOnly` and `-WhatIf` validate supplied metadata through the permanent
`Test-AvmModuleMetadata -InputObject` API. They do not clone templates, require
GitHub authentication, read or update the inventory, write metadata, create
repositories, install modules, or submit app installation requests.
Template-specific checks therefore happen during apply.
Apply checks Git, GitHub CLI, and GitHub authentication before any publication
or app-request dependency installation, including app-only runs.

Apply first validates the supplied metadata when a new repository is requested.
Unless `-skipMetaDataCreation` is set, it then performs the original inventory
publication: fork/clone `toolingRepoUrl`, refresh from `upstream/main`, append the
explicit creation row to
`repository-management/repository-sync/config/repository-metadata.csv`, sort by
`moduleId`, and publish the `chore/add/{moduleName}` branch and
`chore: add {moduleName} metadata` pull request. Existing CSV rows are not replaced
or used as input to metadata.json; the legacy primary/secondary owner columns
also do not truncate metadata.json's full owner array.

For repository creation, apply next clones the existing Terraform template into
an isolated working directory, calls the permanent initializer, and prepares a
fresh initial commit locally. Only then does it create the empty public
repository and push that commit.
The remote-template creation shortcut is deliberately not used: it would publish
files before metadata had been initialized.

Initialization honors `.avm/.disable`. An existing `metadata.json` is validated
and preserved byte-for-byte, including its telemetry identifier; an invalid file
or incorrect filename casing stops publication without overwriting it. The
request supplies metadata only when the file is absent. Supply the actual
existing telemetry identifier when preparing a template that already emits it.
Creation never enables `UpdateSource`, changes telemetry source, or repairs
deployed identifiers.

Working directories default to `out/repository-creation` under the current
directory; `-tempPath` retains its legacy parameter name for overriding that
location. Successful publication removes its own staging directory. Failures
retain it and report the location. If repository creation succeeds but the push
fails, the error also identifies the created repository. Nothing automatically
deletes a remote repository or force-pushes during rollback; inspect the retained
content and remote state before retrying. Inventory and module publication remain
separate operations: an inventory PR may already exist if a later template check
or module publication fails.

`-metaDataOnly` exits after the inventory update, when that update is enabled;
it does not require the new metadata.json fields. `-skipRepoCreation` still permits
inventory/app publication but does not initialize an existing repository.
`-skipMetaDataCreation` skips only the compatibility inventory update, not
metadata.json initialization for a new repository.
`-skipCreateAppInstallationRequest` still skips the app request.
`-toolingRepoUrl` retains its inventory publication override; it never selects
the Avm.Authoring implementation. No inventory/catalog cutover is made here.
