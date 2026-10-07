# Avm.Authoring

Source for the **`Avm.Authoring`** PowerShell module on the [PowerShell Gallery](https://www.powershellgallery.com/packages/Avm.Authoring).

An earlier name-reservation placeholder release exported a single function, `Get-AvmAuthoringPlaceholder`, which is retained here as a back-compat shim. This module adds the **`avm` CLI dispatcher** with verbs for runtime info (`avm version`), module updates (`avm update`), environment diagnosis (`avm doctor`), repo classification (`avm context`), **content-addressed tool management** (`avm tool list|which|install`), the source-formatting / linting / build-validation trio (`avm format`, `avm lint`, `avm test`), README generation (`avm docs`), and a composition verb (`avm pre-commit`) that runs the trio back-to-back. Each verb is backed by the per-ecosystem Bicep and Terraform engine facades. The purpose, architecture, and engineering rules are in [`docs/quality-spec.md`](../../docs/quality-spec.md).

## Layout

| Path                                              | Purpose                                                                            |
| ------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Avm.Authoring.psd1`                              | Module manifest. Name, GUID, version, exported functions.                          |
| `Avm.Authoring.psm1`                              | Discovery loader. Recursively dot-sources `Private/` -> `Engines/` -> `Public/`.   |
| `Public/`                                         | One file per exported function. File basename equals function name.                |
| `Public/Invoke-Avm.ps1`                           | The `avm` dispatcher. Routes verb paths to cmdlets. Accepts kebab-case flags.      |
| `Public/Get-AvmVersion.ps1`                       | `avm version` -> runtime + module info.                                            |
| `Public/Update-AvmAuthoring.ps1`                  | `avm update` -> update the CurrentUser installation from PowerShell Gallery.       |
| `Public/Invoke-AvmDoctor.ps1`                     | `avm doctor` -> local environment diagnosis.                                       |
| `Public/Get-AvmModuleContext.ps1`                 | `avm context` -> classify the current directory as a Bicep or Terraform module.    |
| `Public/Initialize-AvmModule.ps1`                 | `avm init` -> local Bicep scaffolding, or resumable Terraform repository creation and setup; Bicep `-Proposed` creates only metadata.json. |
| `Public/Test-AvmModuleMetadata.ps1`                | `avm metadata validate` -> validate root or child metadata using the packaged schema. |
| `Public/Get-AvmModuleMetadata.ps1`                 | `avm metadata show` -> read and validate an existing metadata.json file. |
| `Public/Initialize-AvmModuleMetadata.ps1`          | `avm metadata initialize` -> create metadata.json without overwriting an existing file. |
| `Public/Get-AvmCatalogTelemetryPrefix.ps1`       | Read published current and historical telemetry identifiers for initialization and repository creation. |
| `Public/Get-AvmTool.ps1`                          | `avm tool list` / `avm tool which` -> inspect locked tools and cache/PATH state.   |
| `Public/Install-AvmTool.ps1`                      | `avm tool install` -> download, SHA256-verify, and cache a locked tool.            |
| `Public/Invoke-AvmFormat.ps1`                     | `avm format` -> route to the bicep / terraform engine and format module sources.   |
| `Public/Invoke-AvmLint.ps1`                       | `avm lint` -> route to the bicep / terraform engine and run lint diagnostics.      |
| `Public/Invoke-AvmTest.ps1`                       | `avm test` -> route to the bicep / terraform engine and run build-validation.      |
| `Public/Invoke-AvmDocs.ps1`                       | `avm docs` -> route to the bicep / terraform engine and refresh README content.    |
| `Public/Export-AvmReadmeNote.ps1`                 | `avm docs export-notes` -> extract authored legacy Notes once without overwriting an existing sidecar. |
| `Public/Invoke-AvmPreCommit.ps1`                  | `avm pre-commit` -> validate metadata, then run the ecosystem's authoring chain.  |
| `Public/Invoke-AvmTestE2e.ps1`                    | `avm test e2e` -> deploy selected examples, run assertions and clean up. |
| `Public/Invoke-AvmTestCleanup.ps1`                | `avm test cleanup` -> resume Bicep cleanup from retained local state. |
| `Public/Register-AvmFeature.ps1`                  | `avm register-features` -> register root-declared Azure features on an explicitly selected test subscription. |
| `Public/Get-AvmAuthoringPlaceholder.ps1`          | Back-compat shim from the initial placeholder release.                             |
| `Engines/`                                        | Per-ecosystem facades over real toolchains. Loaded by the module but not exported. |
| `Engines/Bicep/Format-AvmBicepModule.ps1`         | Runs `bicep format` over every `.bicep` / `.bicepparam` source in the module.      |
| `Engines/Bicep/Invoke-AvmBicepLint.ps1`           | Runs `bicep lint` per `.bicep` file and surfaces structured diagnostics.           |
| `Engines/Bicep/Invoke-AvmBicepTest.ps1`           | Runs `bicep build --stdout` per `.bicep` file as a no-network compile check.       |
| `Engines/Bicep/Invoke-AvmBicepTestUnit.ps1`       | Runs module Pester unit tests in isolation; `-IncludeCompliance` adds packaged native conventions, metadata and README checks. |
| `Engines/Bicep/Invoke-AvmBicepTestIntegration.ps1` | Validates and previews Bicep `tests/e2e` with Azure CLI using temporary, token-substituted ARM templates. |
| `Engines/Bicep/Invoke-AvmBicepTestE2e.ps1`        | Native deployment, assertions, post hooks and operation-based cleanup at all four ARM scopes. |
| `Engines/Bicep/Invoke-AvmBicepDocs.ps1`           | Renders Bicep READMEs through the pinned CLI and a repository-selected Scriban template. |
| `Engines/Terraform/Format-AvmTerraformModule.ps1` | Runs `terraform fmt -recursive` over the module root.                              |
| `Engines/Terraform/Invoke-AvmTerraformLint.ps1`   | Runs the vendored TFLint rulesets per root, module, and example scope.              |
| `Engines/Terraform/Invoke-AvmTerraformTest.ps1`   | Validates examples and warns about uncovered local modules.                      |
| `Engines/Terraform/Invoke-AvmTerraformDocs.ps1`   | Runs `terraform-docs markdown table` in inject mode against the module README.     |
| `Engines/Terraform/Initialize-AvmTerraformRepository.ps1` | Resumable `avm init` stages for a Terraform repository; see [Initialize a Terraform module repository](#initialize-a-terraform-module-repository). |
| `Private/GitHub/`                                 | GitHub CLI and Git wrappers, team access, ruleset opt-out, and app installation requests. |
| `Private/`                                        | Module-internal helpers organised by feature. Dot-sourced but not exported.        |
| `Private/Context/`                                | Repo/module classification walker.                                                 |
| `Private/Docs/`                                   | Bicep template, Notes, source-example, and compiled-resource documentation helpers. |
| `Private/Dispatch/`                               | Verb registry + `.avm/.disable` sentinel.                                          |
| `Private/Exceptions/AvmExceptions.ps1`            | Typed exception classes (`AvmException` base + specialisations).                  |
| `Private/Folders/Get-AvmFolder.ps1`               | Cross-OS resolver for Config/Cache/Data/State/Tools/Logs/Temp folders.             |
| `Private/Layout/Test-AvmModuleLayout.ps1`         | Module-shape validator used by `./build.ps1 layout` and the publish gate.          |
| `Private/Process/Invoke-AvmProcess.ps1`           | Subprocess primitive: argv-verbatim, stdout/stderr capture, exit/timeout policy.   |
| `Private/Tools/Get-AvmToolPlatform.ps1`           | Detect host platform string (e.g. `windows-amd64`) for tool sha256 lookup.         |
| `Private/Tools/Test-AvmPins.ps1`             | Schema validator for `avm.pins.jsonc`. Throws on any violation.                   |
| `Private/Tools/Read-AvmPins.ps1`             | Load + validate a lock file. Defaults to the bundled `Resources/avm.pins.jsonc`.  |
| `Private/Tools/Invoke-AvmHttp.ps1`                | HTTPS/file download primitive with SHA256 verify, TLS pin, AVM_OFFLINE/MIRROR.     |
| `Private/Tools/Expand-AvmToolArchive.ps1`         | Extract `zip` / `tar.gz` / `raw` archives into a staging directory.                |
| `Private/Tools/Lock-AvmToolCache.ps1`             | Cross-process file lock under `<Tools>/<name>/.lock` (retry, timeout).             |
| `Private/Tools/Install-AvmToolFromPins.ps1`       | One-tool install orchestrator: stage -> verify -> atomic rename -> `.verified`.    |
| `Private/Tools/Find-AvmToolOnPath.ps1`            | PATH fallback resolver used by `Get-AvmTool` when no cache hit is present.         |
| `Private/Tools/Resolve-AvmTool.ps1`               | Cache-first path resolver used by the engines (cache -> optional PATH -> throw).   |
| `Resources/PSScriptAnalyzerSettings.psd1`         | Lint rules consumed by `./build.ps1 lint`.                                         |
| `Resources/Schemas/v1/`                           | Authoritative, packaged module metadata and catalog JSON schemas.                 |
| `Resources/avm.pins.jsonc`                       | Bundled tool manifest. Populated entries for `bicep` and `terraform` with per-platform SHA256. |
| `Resources/bicep/avm-readme-v1.scriban`          | Versioned, model-driven Bicep README template; copy into the repository and select it in `bicepconfig.json`. |
| `Resources/Scaffolds/Terraform/`                 | Minimal Terraform module files written by `avm init`.                             |

### Exception taxonomy

| Class                        | Code      | Raised when                                                                            |
| ---------------------------- | --------- | -------------------------------------------------------------------------------------- |
| `AvmException`               | `AVM0000` | Base for everything below. Carries a `Code` property used by exit-code translation.    |
| `AvmConfigurationException`  | `AVM1001` | User-visible config error: `AVM_OFFLINE=1` blocks https, `.avm/.disable` sentinel, ... |
| `AvmContextException`        | `AVM1030` | `Get-AvmModuleContext` cannot classify the current directory.                          |
| `AvmToolException`           | `AVM1010` | Generic tool-resolver failure. Subcodes: `AVM1011` SHA mismatch, `AVM1012` missing     |
|                              |           | platform, `AVM1013` missing entrypoint, `AVM1014` cache-miss + no PATH match.          |
| `AvmProcessException`        | `AVM1020` | `Invoke-AvmProcess` failed to start or returned non-zero (unless `-IgnoreExitCode`).   |
| `AvmGitHubException`         | `AVM1070` | A GitHub API call made through the GitHub CLI failed; `StatusCode` holds the HTTP status. |

### Context resolution

`Get-AvmModuleContext` (and `avm context`) classifies a directory as one of
`bicep-monorepo`, `bicep-module`, `terraform-module-repo` or
`terraform-module-path`. Resolution order, highest precedence first:

1. **Committed `.avm/context.psd1` override** at the authoritative root. Schema:
   ```powershell
   @{
       Ecosystem = 'bicep'         # bicep | terraform   (required)
       Kind      = 'bicep-module'  # bicep-monorepo | bicep-module |
                                   # terraform-module-repo | terraform-module-path  (required)
       Scope     = 'res'           # res | ptn | utl     (optional, bicep only)
       Owner     = '@Azure/avm-core'  # optional, free-form
   }
   ```
   Use this when a repo's layout needs an explicit, audit-friendly
   classification. A conflicting `-Ecosystem` value throws.
2. **Direct source at the root**: `*.bicep` selects `bicep-module`; `*.tf`
   selects Terraform. `terraform.tf` selects `terraform-module-repo`, otherwise
   the kind is `terraform-module-path`.
3. **Bicep monorepo signature**: `bicepconfig.json` plus at least one
   `avm/{res,ptn,utl}/` folder.

PWD, or explicit `-Path <dir>`, is the authoritative root. Parent directories
are never searched for context. Convention folders do not participate in
detection. The full authoritative path is rejected if any directory segment is
a known nested/admin name, with guidance to run from the module root. This can
also reject a checkout whose higher parent directory happens to use a reserved
name. Mixed direct Bicep and Terraform source requires explicit `-Ecosystem`.

## Bicep deployment tests

`avm pr-check` runs static authoring checks. `avm test unit` runs module-owned
Pester separately. `avm test e2e` deploys the complete selected test template,
runs its case-local Pester assertions, runs `post.ps1` if present, and cleans
up through the native Azure PowerShell handlers. The reaper is a fallback.

Use explicitly authorized test targets and existing matching Azure CLI and
Azure PowerShell sign-ins. Required Az modules are checked, not installed.
Cleanup follows deployment operations and can remove resources updated by
a test as well as resources created by it. Resource-group entry points
additionally require `--resource-group-prefix`; management-group entry
points require `--management-group-id`.

```powershell
avm test e2e --list
avm test e2e --example defaults --subscription-id $testSubscriptionId --tenant-id $testTenantId --location eastus
```

State is retained in a unique OS-temporary JSON file and its path is reported.
It contains identifiers and cleanup progress, not parameters, outputs or
credentials. For one selected case, `--cleanup-state-path` selects a new file.
`--phase Deploy` retains resources for `--phase Complete` after the caller
renews its sign-ins. Keep the same direct test/module sources, assertions
and post hook; completion does not fingerprint every imported dependency.
In Actions, retain state even when deployment fails, and upload it as an
artifact for recovery after the runner exits. Recovery is possible only
after that upload finishes.

To resume cleanup without replaying assertions or hooks, pass a trusted
state file and its explicit target identity:

```powershell
avm test cleanup --state-path $statePath --subscription-id $testSubscriptionId --tenant-id $testTenantId
```

Assertions and post hooks run in the current process; cancellation leaves
state for recovery. `--keep-resources` runs assertions but skips both the
post hook and cleanup. `--use-ci-inputs` opts into typed CI values and token
inputs; explicit parameters override them. See
`Get-Help Invoke-AvmTestE2e -Full` for inputs, retries and phase options.

## Module metadata

Root `metadata.json` files use the required versioned `$schema` reference to
select the authored format:

```json
{
  "$schema": "https://raw.githubusercontent.com/Azure/azure-verified-modules-tools/main/src/Avm.Authoring/Resources/Schemas/v1/avm-module-metadata.schema.json",
  "moduleDisplayName": "Storage Accounts",
  "moduleDescription": "Deploys a Storage Account.",
  "canonicalType": "Microsoft.Storage/storageAccounts",
  "telemetryIdPrefix": "46d3xtrf.res.storage-storageaccount",
  "owners": ["owner-one", "@Azure/team-name"]
}
```

`owners` is a flat array of bare GitHub usernames and qualified team handles;
it can contain any number of either, including none (`[]`). Handles must be
unique ignoring case. Children omit `owners` and inherit root ownership.
Authored files have no `schemaVersion`, `tier`, or lifecycle status property;
unknown properties are rejected.

Use `New-AvmTelemetryIdPrefix -Ecosystem bicep -Kind res -KnownPrefix $existing`
to mint a unique seven-character hexadecimal prefix. Include both current
and historical prefixes in `$existing`. An optional
`alternativeTelemetryIdPrefixes` array in metadata preserves previous
identifiers; generated catalog JSON includes this array even when empty.

Resource `canonicalType` values use full, case-sensitive `Microsoft.*` or
`Oracle.Database` ARM types, such as `Oracle.Database/cloudVmClusters`.
Pattern/utility taxonomy names such as `naming` and paths such as `lz/sub-vending`
remain distinct. A resource type cannot embed a second dotted namespace.

Exact lowercase `canonicalType: "helper"` marks a child/submodule, never a root,
ARM type, or new module kind. Bicep and Terraform helpers keep their family's
resource/pattern/utility kind, required child fields, and inherited owners.
Telemetry is optional; supplied prefixes retain normal ecosystem, kind, format,
and length validation. Catalog JSON includes helpers under `helper`, with null
`providerNamespace` and `resourceType`; all generated CSVs exclude them.

`Get-AvmModuleMetadata` reads existing files only and fails when a file is
missing. `Test-AvmModuleMetadata -InputObject` validates supplied values without
reading `metadata.json`. `Initialize-AvmModuleMetadata` accepts partial
metadata, supplies the bundled `$schema` URI and any required Bicep telemetry
prefix, and preserves existing files. It prompts for missing fields only in an
interactive terminal; noninteractive callers get a list of required fields.
The prefix is generated against published catalog IDs and local Bicep module
metadata, including historical alternatives. Catalog failures warn while
local metadata remains mandatory and validated. No CSV index is used to
infer values; metadata-only initialization does not read source.
If `Initialize-AvmModuleMetadata -UpdateSource` is explicitly requested,
an omitted prefix instead preserves the single valid value already authored
in main.bicep; conflicting values or duplicates from other modules fail
before writing. Metadata-only initialization does not inspect or modify source.

For a proposed Bicep module, install or update Avm.Authoring yourself, import
it, then initialize its metadata without creating `main.bicep` or other files:

```pwsh
avm init -Ecosystem bicep -ModuleType resource -Path ./avm/res/storage/storage-account -Proposed
```

The missing module and provider directories are created after validation.
Provide `-InputObject` for scripted use, or answer prompts for the module
display name, description, canonical type, and owners (empty is allowed).
For Terraform, see
[Initialize a Terraform module repository](#initialize-a-terraform-module-repository).
Without `-Proposed`, Bicep `avm init` writes `metadata.json`, `main.bicep`,
`version.json`, `CHANGELOG.md`, and defaults and WAF-aligned
`tests/e2e/*/main.test.bicep` for a new root. It neither generates
`main.json`/`README.md` nor deploys or publishes anything. Existing files are
validated and left unchanged; a proposed module can therefore be completed
later without changing its metadata or telemetry prefix. New utilities
without telemetry get a telemetry-free source template.

For a nested Bicep module, pass `-ChildModule` and the target's metadata in
`-InputObject`. Full initialization creates missing ancestors from the
root through the target in one validated operation; root-only files stay
at the root. Interactive users are prompted for required fields on every
missing ancestor. For a noninteractive deep child, supply missing ancestor
metadata through `-AncestorInputObject`:

```pwsh
$rootMetadata = @{
    moduleDisplayName = 'Storage Accounts'
    moduleDescription = 'Deploys a Storage Account.'
    canonicalType = 'Microsoft.Storage/storageAccounts'
    owners = @('module-owner')
}
$childMetadata = @{
    moduleDisplayName = 'Blob Services'
    moduleDescription = 'Deploys a blob service.'
    canonicalType = 'Microsoft.Storage/storageAccounts/blobServices'
}
avm init -Ecosystem bicep -ModuleType resource `
    -Path .\avm\res\storage\storage-account\blob-service `
    -ChildModule -InputObject $childMetadata `
    -AncestorInputObject @{ '.' = $rootMetadata }
```

Map keys are exact lowercase root-relative Bicep paths: `.` denotes the
root, and `blob-service` or `blob-service/container` denotes an intermediate
ancestor. Use `/` within keys on every OS. Values for existing ancestors
are ignored; their files and prefixes remain unchanged. Without required
metadata in CI, initialization names the missing ancestor and its fields
rather than prompting. Newly scaffolded uninstrumented children do not
invent telemetry prefixes. `-Proposed` remains metadata-only for a single
target and does not accept ancestor metadata. Both modes support `-WhatIf`
and validate the whole plan before creating files; partial writes are
rolled back on failure.

Bicep's optional `Initialize-AvmModuleMetadata -UpdateSource` loads only its
telemetry prefix; a helper without a prefix leaves source unchanged.
Terraform rejects `-UpdateSource` before writes and never
generates `main.metadata.tf`; later telemetry changes belong in MaPoTF.
Existing authored source files are preserved. Metadata-only initialization
does not rewrite source. Pre-commit and PR checks require valid metadata on
every module root and child. Required tools resolve first; metadata validation
then stops the chain on missing or invalid files before other steps or module-file
changes. Initialize missing files with `avm metadata initialize` before
rerunning either check.

## Initialize a Terraform module repository

`avm init` creates and sets up a Terraform module repository in the `Azure`
GitHub organization. Install Git and the GitHub CLI, sign in with
`gh auth login` (the token needs the `repo`, `read:org`, and `workflow`
scopes), then run:

```pwsh
avm init -Ecosystem terraform -ModuleType resource -Path ./terraform-azure-avm-res-storage-storageaccount
```

The folder name is the repository name; inside an existing clone the `origin`
remote identifies it instead. If the folder name is not a valid
`terraform-<provider>-avm-<res|ptn|utl>-<name>`, `avm init` asks for the name
and uses a folder of that name beneath `-Path`. Missing metadata is prompted
for or supplied with `-InputObject`. Resource and pattern modules get a new
telemetry identifier unless one is supplied.

Each stage checks what already exists, so rerunning the command after an
interruption continues where it stopped. A failed stage is reported and
stops the run:

1. Write `metadata.json` to the folder, which keeps the answers for later runs.
1. Create the public repository if it does not exist.
1. Wait for the open source portal setup and just-in-time (JIT) elevation,
   printing the portal answers. A non-interactive session stops here.
1. Grant `azure-verified-modules-module-contributors` push and
   `azure-verified-modules-module-readers` triage access. Higher existing
   access is kept.
1. Publish the first commit to `main` from a temporary clone: the portal's
   seed files, `metadata.json`, the minimal scaffold from
   `Resources/Scaffolds/Terraform` (an AzAPI virtual network that takes
   `parent_id`, with the AzAPI `resource_types`, `retry`, `timeouts` and
   `ignore_body_changes` inputs, and a default example that uses the regions
   and naming utility modules), and the current managed files, telemetry,
   and README added by `avm pre-commit`. Nothing else from your folder is
   published, and a `main` that already holds module files is never
   overwritten. When `main` already has `metadata.json`, the run checks that
   `terraform.tf`, `_header.md`, an example folder, and `tests/` exist too.
1. Open a pull request in `microsoft/github-operations` for the AVM and
   Terraform Cloud app installations, unless the repository is listed or an
   open request exists. Repository sync finishes the setup after installation.
1. Clone the repository into the folder when it is empty or holds only the
   published `metadata.json`. The clone is made beside the folder and then
   moved into place, so a failed clone leaves the folder as it was. Otherwise
   your files are left untouched.
1. Show the final Open Source Portal steps, which `avm init` cannot check
   because the portal offers no API for them. Both are listed with the status
   `manual` on every completed run:
   1. Tie the repository to the shared
      `service-AVM-azure-verified-modules-module-owners` just-in-time rule,
      which also upgrades it to JIT v2. Do it after the stages above, which
      need your elevated access. If you cannot propose the tie, email
      avm@microsoft.com instead.
   1. **Last, once everything else is done**, make `jaredholgate` and
      `jatracey` the only individual Direct Owners. While elevated to
      administrator, select **Change owners** under Direct Owners on the
      repository overview, remove everyone else, including yourself and
      whoever created the repository, and keep the
      `azure-verified-modules-module-owners` fallback security group.

The organization's production ruleset requires pull requests on `main`, even
for JIT-elevated administrators. The first push therefore runs with the
repository's `global-rulesets-opt-out` custom property temporarily set to
`true`. The original value is recorded in the `repository-init` folder of the
Avm state directory before the change and restored afterwards. If the run stops
before restoring it, the next run on the same machine restores the recorded
value, provided the property is still `true` and repository sync does not
manage the repository. A record left for a deleted repository of the same name
is discarded. If the property is already `true`, repository sync does not
manage the repository, and this machine has no record, the original value is
unknown, so the run stops until the property is set back. Repository sync keeps
the property `true` and adds its own ruleset, which also requires pull requests,
so a synced repository without module files needs its first commit through a
pull request.

`-WhatIf` reports the stages that would run without changing anything.
Declining a `-Confirm` prompt stops the run at that stage. Terraform
`-ChildModule` initialization creates only the child's `metadata.json`.

### Use an agent

An AI agent such as GitHub Copilot CLI can guide you through the whole setup
with the
[`avm-tf-module-repository-creation`](../../.github/skills/avm-tf-module-repository-creation/SKILL.md)
agent skill. The skill collects the approved values from the module proposal,
runs `avm init`, relays the Open Source Portal steps, checks the result, and
finishes with the Direct Owners step. It asks for your approval before it
creates the repository and before it changes anything in the portal for you.

Install it for your user account with GitHub CLI 2.90.0 or later, then ask
your agent to create the repository for your approved module:

```pwsh
gh skill install Azure/azure-verified-modules-tools .github/skills/avm-tf-module-repository-creation --scope user
```

`gh skill install` takes the skill from the latest release of this repository,
so it matches the released `avm init`. `gh skill update` updates it later.

## Local smoke test

The source manifest has version `0.0.0`. For local source commands other than
`avm version` and `avm update`, pass `-SkipModuleVersionCheck` immediately after
`avm`; installed releases enforce the latest Gallery version by default.
`avm version` still returns the running version and warns when an update is
available.

From the repo root:

```pwsh
Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force

avm -SkipModuleVersionCheck  # dispatcher help (writes via Information stream)
avm version         # Get-AvmVersion
avm update          # Update-AvmAuthoring
avm -SkipModuleVersionCheck doctor          # Invoke-AvmDoctor
avm -SkipModuleVersionCheck doctor --json   # GNU-style flag translates to -Json
avm -SkipModuleVersionCheck context         # Get-AvmModuleContext (current working directory)
avm -SkipModuleVersionCheck init -Ecosystem bicep -ModuleType resource -Path ./avm/res/storage/storage-account -Proposed
avm -SkipModuleVersionCheck tool list       # Get-AvmTool (lists all tools in the bundled lock)
avm -SkipModuleVersionCheck format          # Invoke-AvmFormat (engine resolved from module context)
avm -SkipModuleVersionCheck lint            # Invoke-AvmLint (bicep lint; scoped AVM TFLint rulesets for terraform)
avm -SkipModuleVersionCheck test            # Invoke-AvmTest (bicep build --stdout; terraform validate -json per example)
avm -SkipModuleVersionCheck test --no-init  # Use initialized examples; module coverage is not assessed
avm -SkipModuleVersionCheck docs            # Invoke-AvmDocs (terraform-docs inject; Bicep Scriban template)
avm -SkipModuleVersionCheck pre-commit      # Terraform: metadata -> sync -> check convention -> transform -> format -> docs
avm -SkipModuleVersionCheck pre-commit -Ecosystem terraform -ManagedFilesLocalPath D:\managed-files\terraform\files -ConfigLocalPath D:\tools\repository-management\repository-config -RepoId avm-res-foo

Remove-Module Avm.Authoring
```

The bundled `Resources/avm.pins.jsonc` ships verified hashes for `bicep`, `terraform`, `tflint`, and `terraform-docs`; `avm tool list` returns those entries out of the box. Tests cover the install pipeline end-to-end via `file://` fixtures under `tests/Pester/Unit/Public/`.

Terraform validation includes every direct example, even `.e2eignore` examples.
It warns if the checkout's root module or a direct `modules/` configuration is
not reached by an example. Registry/Git copies and test-only helper modules do
not count. Coverage gaps are non-failing; no examples returns `skipped`.

The Terraform lint bundle pins TFLint 0.64.0 and `tflint-ruleset-avm` 1.0.0.
All three packaged configurations require GitHub Artifact Attestation; there is
no PGP signing-key fallback.

AVM rules use the canonical `avm_*` names and are enabled by default in the
ruleset. The packaged configurations declare scope-specific disables plus native
severity overrides. The root and submodule configurations are strict; examples
retain only the deliberate interface and module-only exemptions. The standard
Terraform rules remain explicitly curated under their unchanged names.

Three rule families stay enabled with native `severity = "notice"` configuration,
so TFLint reports them on every run with file and line while the default warning
threshold still passes: the TFFR6/7/8 rules
`avm_interface_resource_types`, `avm_interface_retry`,
`avm_interface_timeouts`, `avm_interface_ignore_body_changes`,
`avm_azapi_response_export_values_required`, and
`avm_azapi_data_response_export_values_required`; the TFFR3 rule
`avm_provider_azurerm_disallowed`; and the TFFR2 rule
`avm_output_entire_resource_disallowed`. Avm.Authoring no longer carries a
hard-coded demotion list or rewrites plugin severities. See
[Azure/azure-verified-modules-tools#80](https://github.com/Azure/azure-verified-modules-tools/issues/80)
for the enforcement burn-down.

For `azapi_resource`, omit `replace_triggers_refs` when no immutable body
property requires replacement. When it is declared, it must be a static,
non-empty list of unique, nonblank JMESPath expressions that resolve against the
resource body; do not include the redundant `name` or `location` paths. The
1.0.0 ruleset is installed with GitHub Artifact Attestation.

### Terraform TFLint overrides

Repository-root override files remain supported:

```text
avm.tflint.override.hcl          # root scope
avm.tflint_module.override.hcl   # every direct modules/* scope
avm.tflint_example.override.hcl  # every direct examples/* scope
```

To override one direct scope without changing siblings, add:

```text
modules/<name>/avm.tflint.override.hcl
examples/<name>/avm.tflint.override.hcl
```

AVM permits only one module or example child layer, so
`modules/network/avm.tflint.override.hcl` applies to `modules/network`.
Overrides merge by attributes, in this order: packaged config, matching
all-scope override, then matching per-scope override. Per-scope paths are
validated and staged under a hash-named config, so they cannot escape the
repository root or collide with another scope.

### Refreshing the tools lock

Maintainers refresh canonical entries with `scripts/Update-AvmPins.ps1`. The script fetches official checksums (terraform, tflint, terraform-docs) or downloads each per-platform binary and computes SHA256 locally (bicep), validates the result through `Test-AvmPins`, then rewrites `Resources/avm.pins.jsonc` with deterministic formatting.

```powershell
# Refresh every supported tool
./scripts/Update-AvmPins.ps1 -Terraform 1.15.8 -Bicep 0.30.3 -Tflint 0.64.0 -TerraformDocs 0.20.0

# Refresh just one
./scripts/Update-AvmPins.ps1 -TerraformDocs 0.20.0

# Preview without writing
./scripts/Update-AvmPins.ps1 -Terraform 1.15.8 -WhatIf
```

The lock schema accepts an optional `platformAliases` map for tools whose release assets don't follow `{os}_{arch}` naming (such as bicep). When present, `urlTemplate` may reference the `{platform}` placeholder, which is substituted per-platform at download time. It also accepts an optional `unsupportedPlatforms` array for tools that don't ship a build for every platform (tflint, for example, has no `windows-arm64` release); listed platforms must be ABSENT from `sha256` and runtime resolve/install throws `AvmToolException` (AVM1012) when the current host matches. Finally, an optional `archives` map allows tools that ship different archive types per OS (terraform-docs, for example, uses `tar.gz` on darwin/linux and `zip` on windows) — when present, every supported platform must be listed and `urlTemplate` may reference the `{ext}` placeholder which expands to `.zip` / `.tar.gz` / `''` per the resolved archive type. don't follow `{os}_{arch}` naming (such as bicep). When present, `urlTemplate` may reference the `{platform}` placeholder, which is substituted per-platform at download time. It also accepts an optional `unsupportedPlatforms` array for tools that don't ship a build for every platform (tflint, for example, has no `windows-arm64` release); listed platforms must be ABSENT from `sha256` and runtime resolve/install throws `AvmToolException` (AVM1012) when the current host matches.

## Tool cache layout

Installed tools live under `<Data>/tools/` (resolved by `Get-AvmFolder -Kind Tools` per `docs/quality-spec.md` §10):

```
<Data>/tools/<name>/
  .lock                    # cross-process file lock (Lock-AvmToolCache)
  .staging/<short-uuid>/   # in-flight extraction; renamed into place on success
  <version>/
    <entrypoint>[.exe]     # the binary itself (lowercase entrypoint)
    .verified              # marker file written last (cache-hit gate)
    .meta.json             # { name, version, platform, url, sha256, archive, installedAt }
```

The full contributor workflow (`./build.ps1 pre-commit`, individual Pester runs, publish flow) is in [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Publish to PSGallery

The Azure DevOps release pipeline stages, ESRP-signs, verifies, and uploads the module archive. After ADO promotes the release, GitHub Actions uses the trusted default-branch `scripts/Publish-AvmAuthoring.ps1` to validate the signed archive and publish it to PSGallery. The publisher repeats the case-sensitive layout checks that the `layout` build task uses.
