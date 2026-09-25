# Repository creation

[`scripts/New-Repository.ps1`](scripts/New-Repository.ps1) is the operator-driven
Terraform repository creation entry point. It initializes `metadata.json`
through `Initialize-AvmModuleMetadata` before publishing the repository's first
commit. There is no separate tooling-repository inventory registration.
Creation does not read CSV indexes or infer missing values from source.

Run from a trusted checkout of this tools repository using PowerShell 7.4+.
Creation imports `src/Avm.Authoring/Avm.Authoring.psd1` directly, not an installed
Gallery version. It does not install or update Avm.Authoring. Applying requires
authenticated `gh`, repository-creation and Git push access, permission to edit
repository custom properties, and a configured Git commit identity. The optional
app installation request retains its existing `powershell-yaml` installation step.
Existing open-source portal setup prompts still run after publication.

## Explicit inputs

```pwsh
$request = @{
    moduleName = 'avm-res-storage-storageaccount'
    moduleDisplayName = 'Azure Storage Account'
    moduleDescription = 'Deploys an Azure Storage account.'
    resourceProviderNamespace = 'Microsoft.Storage'
    resourceType = 'storageAccounts'
    telemetryIdPrefix = '46d3xtrf.res.a1b2c3d'
    ownerPrimaryGitHubHandle = 'first-owner'
    ownerSecondaryGitHubHandle = 'second-owner'
    ownerGitHubHandles = @('third-owner')
    ownerTeam = '@Azure/storage-owners'
}

# Validate the supplied values and show the plan without filesystem or GitHub writes.
.\repository-management\repository-creation\scripts\New-Repository.ps1 @request -PlanOnly

# After reviewing the plan, omit -PlanOnly to create and publish.
```

The values above are illustrative: supply the requested module's actual
description, canonical type, telemetry identifier, and owners.

## Telemetry identifiers

Omit `telemetryIdPrefix` and creation mints one for a resource or pattern root as
`46d3xtrf.<res|ptn>.<7 lowercase hex characters>`, matching the convention
already used across the Terraform fleet. Utilities may be telemetry-free, so an
omitted identifier stays omitted for `avm-utl-` modules. The suffix is random
rather than derived from the module name. Creation calls the checked-out
Avm.Authoring `New-AvmTelemetryIdPrefix` cmdlet with the current and historical
prefixes from the published module catalog at
`https://raw.githubusercontent.com/Azure/Azure-Verified-Modules/main/docs/static/module-indexes/v1/modules.json`
before it is used. `-CatalogUri` on `Get-AvmRepositoryCatalogTelemetryPrefix`
also accepts a local path, which is useful when reviewing a catalog artifact
downloaded from a workflow run.

If that catalog cannot be resolved, creation warns and continues with an
unchecked identifier rather than failing. Supply `-telemetryIdPrefix` explicitly
to keep an identifier a module already emits. Because the value is random, a
`-PlanOnly` run and the subsequent apply show different generated identifiers.

| Metadata field | Creation input |
| --- | --- |
| `$schema` | `$id` of the schema packaged in the checked-out module |
| `moduleDisplayName` | `moduleDisplayName` |
| `moduleDescription` | Required `moduleDescription`; never copied from a display name |
| `canonicalType` | Required `canonicalType`; resource modules may instead supply both `resourceProviderNamespace` and `resourceType` |
| `telemetryIdPrefix` | Explicit `telemetryIdPrefix`, or a generated unique identifier for resource and pattern roots when omitted |
| `owners` | Flat array of primary/secondary handles, additional `ownerGitHubHandles`, and optional qualified `ownerTeam` |
| `alternativeNames` | Comma-separated `moduleAlternativeNames`, trimmed with empty and duplicate entries removed |

No owner is inferred. An empty owner array is valid; there is no two-owner
limit. Handles must satisfy the schema, without a leading `@` for individuals.
Teams use `@organization/team-slug`. The versioned `$schema` is required;
module metadata has no additional `schemaVersion` or `tier` field.
Pattern and utility canonical taxonomy paths must be supplied explicitly;
creation never guesses them from a repository name. Conflicting resource
namespace/type and canonical type inputs fail visibly.

`moduleAlternativeNames` retains its string parameter type and is split into
metadata aliases. No values are inferred from an inventory.

The module kind comes from `avm-res-`, `avm-ptn-`, or `avm-utl-`; the ecosystem is
Terraform. Creation does not initialize child modules.

## Plan, publication, and recovery

`-PlanOnly` and `-WhatIf` validate supplied metadata through the permanent
`Test-AvmModuleMetadata -InputObject` API. They do not clone templates, require
GitHub authentication, write metadata, change custom properties, create
repositories, install modules, or submit app installation requests.
Template-specific checks therefore happen during apply.
Apply checks Git, GitHub CLI, and GitHub authentication before any publication
or app-request dependency installation, including app-only runs.

Apply validates the supplied metadata, then clones the Terraform template into
an isolated working directory, calls the permanent initializer, and prepares a
fresh initial commit locally. Only then does it create the empty public
repository.
The remote-template creation shortcut is deliberately not used: it would publish
files before metadata had been initialized.

Before the first push to `main`, creation records the new repository's
`rulesets-default-opt-in` custom-property value in `ruleset-recovery.json`
outside the staged module. Unless already `"false"`, it temporarily sets that
property to `"false"` and verifies readback. A `finally` block restores and
verifies the original value after success or failure; `null` resets an
originally unset property. An existing `"false"` is left unchanged.
No production/global ruleset properties, organization rulesets, or established
repository protections are changed. Plans include this temporary exception.

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
content and remote state before retrying. If the push succeeded but restoration
failed, the error explicitly reports the published commit and the required
recovery. Restore the recorded property before retrying. Abrupt process
termination may prevent `finally` from running: inspect any retained
`ruleset-recovery.json` and the live property rather than assuming restoration.

`-skipRepoCreation` permits app-installation requests only; it does not initialize
metadata or change protection on an existing repository.
`-skipCreateAppInstallationRequest` still skips the app request.
The CSV-only `-metaDataOnly`, `-skipMetaDataCreation`, `-toolingRepoUrl`,
`-ownerPrimaryDisplayName`, and `-ownerSecondaryDisplayName` parameters are
removed. For existing repositories, initialize metadata locally through
`avm metadata initialize` and use the normal reviewed contribution process.
Generated public catalog CSVs are unchanged.
