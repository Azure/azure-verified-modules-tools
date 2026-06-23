# Avm.Authoring

Source for the **`Avm.Authoring`** PowerShell module on the [PowerShell Gallery](https://www.powershellgallery.com/packages/Avm.Authoring).

An earlier name-reservation placeholder release exported a single function, `Get-AvmAuthoringPlaceholder`, which is retained here as a back-compat shim. This module adds the **`avm` CLI dispatcher** with verbs for runtime info (`avm version`), environment diagnosis (`avm doctor`), repo classification (`avm context`), **content-addressed tool management** (`avm tool list|which|install`), the source-formatting / linting / build-validation trio (`avm format`, `avm lint`, `avm test`), README generation (`avm docs`), and a composition verb (`avm pre-commit`) that runs the trio back-to-back. Each verb is backed by the per-ecosystem Bicep and Terraform engine facades. The full roadmap is in [`docs/avm-consolidation-plan.md`](../../docs/avm-consolidation-plan.md); the engineering rules are in [`docs/avm-implementation-spec.md`](../../docs/avm-implementation-spec.md).

## Layout

| Path                                              | Purpose                                                                            |
| ------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Avm.Authoring.psd1`                              | Module manifest. Name, GUID, version, exported functions.                          |
| `Avm.Authoring.psm1`                              | Discovery loader. Recursively dot-sources `Private/` -> `Engines/` -> `Public/`.   |
| `Public/`                                         | One file per exported function. File basename equals function name.                |
| `Public/Invoke-Avm.ps1`                           | The `avm` dispatcher. Routes verb paths to cmdlets. Accepts kebab-case flags.      |
| `Public/Get-AvmVersion.ps1`                       | `avm version` -> runtime + module info.                                            |
| `Public/Invoke-AvmDoctor.ps1`                     | `avm doctor` -> local environment diagnosis.                                       |
| `Public/Get-AvmModuleContext.ps1`                 | `avm context` -> classify the current directory as a Bicep or Terraform module.    |
| `Public/Get-AvmTool.ps1`                          | `avm tool list` / `avm tool which` -> inspect locked tools and cache/PATH state.   |
| `Public/Install-AvmTool.ps1`                      | `avm tool install` -> download, SHA256-verify, and cache a locked tool.            |
| `Public/Invoke-AvmFormat.ps1`                     | `avm format` -> route to the bicep / terraform engine and format module sources.   |
| `Public/Invoke-AvmLint.ps1`                       | `avm lint` -> route to the bicep / terraform engine and run lint diagnostics.      |
| `Public/Invoke-AvmTest.ps1`                       | `avm test` -> route to the bicep / terraform engine and run build-validation.      |
| `Public/Invoke-AvmDocs.ps1`                       | `avm docs` -> route to the bicep / terraform engine and refresh README content.    |
| `Public/Invoke-AvmPreCommit.ps1`                  | `avm pre-commit` -> composition: format -> lint -> test against the same context.  |
| `Public/Get-AvmAuthoringPlaceholder.ps1`          | Back-compat shim from the initial placeholder release.                             |
| `Engines/`                                        | Per-ecosystem facades over real toolchains. Loaded by the module but not exported. |
| `Engines/Bicep/Format-AvmBicepModule.ps1`         | Runs `bicep format` over every `.bicep` / `.bicepparam` source in the module.      |
| `Engines/Bicep/Invoke-AvmBicepLint.ps1`           | Runs `bicep lint` per `.bicep` file and surfaces structured diagnostics.           |
| `Engines/Bicep/Invoke-AvmBicepTest.ps1`           | Runs `bicep build --stdout` per `.bicep` file as a no-network compile check.       |
| `Engines/Bicep/Invoke-AvmBicepDocs.ps1`           | Placeholder for the ARM-JSON walker that replaces `Set-ModuleReadMe.ps1`.          |
| `Engines/Terraform/Format-AvmTerraformModule.ps1` | Runs `terraform fmt -recursive` over the module root.                              |
| `Engines/Terraform/Invoke-AvmTerraformLint.ps1`   | Runs `tflint --recursive --format=json` and surfaces structured diagnostics.       |
| `Engines/Terraform/Invoke-AvmTerraformTest.ps1`   | Runs `terraform validate -no-color -json` (with optional auto `terraform init`).   |
| `Engines/Terraform/Invoke-AvmTerraformDocs.ps1`   | Runs `terraform-docs markdown table` in inject mode against the module README.     |
| `Private/`                                        | Module-internal helpers organised by feature. Dot-sourced but not exported.        |
| `Private/Context/`                                | Repo/module classification walker.                                                 |
| `Private/Dispatch/`                               | Verb registry + `.avm/.disable` sentinel.                                          |
| `Private/Exceptions/AvmExceptions.ps1`            | Typed exception classes (`AvmException` base + specialisations, spec section 14).  |
| `Private/Folders/Get-AvmFolder.ps1`               | Cross-OS resolver for Config/Cache/Data/State/Tools/Logs/Temp folders.             |
| `Private/Layout/Test-AvmModuleLayout.ps1`         | Module-shape validator used by `./build.ps1 layout` and the publish gate.          |
| `Private/Process/Invoke-AvmProcess.ps1`           | Subprocess primitive: argv-verbatim, stdout/stderr capture, exit/timeout policy.   |
| `Private/Tools/Get-AvmToolPlatform.ps1`           | Detect host platform string (e.g. `windows-amd64`) for tool sha256 lookup.         |
| `Private/Tools/Test-AvmToolsLock.ps1`             | Schema validator for `tools.lock.psd1`. Throws on any violation.                   |
| `Private/Tools/Read-AvmToolsLock.ps1`             | Load + validate a lock file. Defaults to the bundled `Resources/tools.lock.psd1`.  |
| `Private/Tools/Invoke-AvmHttp.ps1`                | HTTPS/file download primitive with SHA256 verify, TLS pin, AVM_OFFLINE/MIRROR.     |
| `Private/Tools/Expand-AvmToolArchive.ps1`         | Extract `zip` / `tar.gz` / `raw` archives into a staging directory.                |
| `Private/Tools/Lock-AvmToolCache.ps1`             | Cross-process file lock under `<Tools>/<name>/.lock` (retry, timeout).             |
| `Private/Tools/Install-AvmToolFromLock.ps1`       | One-tool install orchestrator: stage -> verify -> atomic rename -> `.verified`.    |
| `Private/Tools/Find-AvmToolOnPath.ps1`            | PATH fallback resolver used by `Get-AvmTool` when no cache hit is present.         |
| `Private/Tools/Resolve-AvmTool.ps1`               | Cache-first path resolver used by the engines (cache -> optional PATH -> throw).   |
| `Resources/PSScriptAnalyzerSettings.psd1`         | Lint rules consumed by `./build.ps1 lint`.                                         |
| `Resources/tools.lock.psd1`                       | Bundled tool manifest. Populated entries for `bicep` and `terraform` with per-platform SHA256. |

### Exception taxonomy

| Class                        | Code      | Raised when                                                                            |
| ---------------------------- | --------- | -------------------------------------------------------------------------------------- |
| `AvmException`               | `AVM0000` | Base for everything below. Carries a `Code` property used by exit-code translation.    |
| `AvmConfigurationException`  | `AVM1001` | User-visible config error: `AVM_OFFLINE=1` blocks https, `.avm/.disable` sentinel, ... |
| `AvmContextException`        | `AVM1030` | `Get-AvmModuleContext` cannot classify the current directory.                          |
| `AvmToolException`           | `AVM1010` | Generic tool-resolver failure. Subcodes: `AVM1011` SHA mismatch, `AVM1012` missing     |
|                              |           | platform, `AVM1013` missing entrypoint, `AVM1014` cache-miss + no PATH match.          |
| `AvmProcessException`        | `AVM1020` | `Invoke-AvmProcess` failed to start or returned non-zero (unless `-IgnoreExitCode`).   |

### Context resolution

`Get-AvmModuleContext` (and `avm context`) classifies a directory as one of
`bicep-monorepo`, `bicep-module`, `terraform-module-repo` or
`terraform-module-path`. Resolution order, highest precedence first:

1. **Committed `.avm/context.psd1` override** anywhere up the tree. Schema:
   ```powershell
   @{
       Ecosystem = 'bicep'         # bicep | terraform   (required)
       Kind      = 'bicep-module'  # bicep-monorepo | bicep-module |
                                   # terraform-module-repo | terraform-module-path  (required)
       Scope     = 'res'           # res | ptn | utl     (optional, bicep only)
       Owner     = '@Azure/avm-core'  # optional, free-form
   }
   ```
   The file's directory becomes `Root`. Use this when a repo's layout does
   not match the default heuristics, or to make classification audit-friendly.
2. **`-Ecosystem bicep|terraform|auto`** parameter (default `auto`). Forces
   the heuristic phase to only consider rules in that ecosystem. A conflict
   between `-Ecosystem` and a `.avm/context.psd1` file throws so contributors
   notice the disagreement instead of silently picking one.
3. **Heuristics**: walks upward looking for the four signatures listed above
   (Plan section 5). Module-path matches win over repo-root matches because
   they are more specific; if both fire at the same directory, repo-root wins.

`-Path <dir>` lets the caller pin the starting directory (equivalent to the
plan's `--module <path>` global flag).

## Local smoke test

From the repo root:

```pwsh
Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force

avm                 # dispatcher help (writes via Information stream)
avm version         # Get-AvmVersion
avm doctor          # Invoke-AvmDoctor
avm doctor --json   # GNU-style flag translates to -Json
avm context         # Get-AvmModuleContext (current working directory)
avm tool list       # Get-AvmTool (lists all tools in the bundled lock)
avm format          # Invoke-AvmFormat (engine resolved from module context)
avm lint            # Invoke-AvmLint   (bicep lint; tflint --recursive for terraform)
avm test            # Invoke-AvmTest   (bicep build --stdout; terraform validate -json)
avm test --no-init  # Skip the implicit 'terraform init -backend=false'
avm docs            # Invoke-AvmDocs   (terraform-docs inject; bicep walker pending)
avm pre-commit      # Invoke-AvmPreCommit (format -> lint -> test)

Remove-Module Avm.Authoring
```

The bundled `Resources/tools.lock.psd1` ships verified hashes for `bicep`, `terraform`, `tflint`, and `terraform-docs`; `avm tool list` returns those entries out of the box. Tests cover the install pipeline end-to-end via `file://` fixtures under `tests/Pester/Unit/Public/`.

### Refreshing the tools lock

Maintainers refresh canonical entries with `scripts/Update-AvmToolsLock.ps1`. The script fetches official checksums (terraform, tflint, terraform-docs) or downloads each per-platform binary and computes SHA256 locally (bicep), validates the result through `Test-AvmToolsLock`, then rewrites `Resources/tools.lock.psd1` with deterministic formatting.

```powershell
# Refresh every supported tool
./scripts/Update-AvmToolsLock.ps1 -Terraform 1.15.3 -Bicep 0.30.3 -Tflint 0.55.1 -TerraformDocs 0.20.0

# Refresh just one
./scripts/Update-AvmToolsLock.ps1 -TerraformDocs 0.20.0

# Preview without writing
./scripts/Update-AvmToolsLock.ps1 -Terraform 1.15.3 -WhatIf
```

The lock schema accepts an optional `platformAliases` map for tools whose release assets don't follow `{os}_{arch}` naming (such as bicep). When present, `urlTemplate` may reference the `{platform}` placeholder, which is substituted per-platform at download time. It also accepts an optional `unsupportedPlatforms` array for tools that don't ship a build for every platform (tflint, for example, has no `windows-arm64` release); listed platforms must be ABSENT from `sha256` and runtime resolve/install throws `AvmToolException` (AVM1012) when the current host matches. Finally, an optional `archives` map allows tools that ship different archive types per OS (terraform-docs, for example, uses `tar.gz` on darwin/linux and `zip` on windows) — when present, every supported platform must be listed and `urlTemplate` may reference the `{ext}` placeholder which expands to `.zip` / `.tar.gz` / `''` per the resolved archive type. don't follow `{os}_{arch}` naming (such as bicep). When present, `urlTemplate` may reference the `{platform}` placeholder, which is substituted per-platform at download time. It also accepts an optional `unsupportedPlatforms` array for tools that don't ship a build for every platform (tflint, for example, has no `windows-arm64` release); listed platforms must be ABSENT from `sha256` and runtime resolve/install throws `AvmToolException` (AVM1012) when the current host matches.

## Tool cache layout

Installed tools live under `<Data>/tools/` (resolved by `Get-AvmFolder -Kind Tools` per `docs/avm-implementation-spec.md` §10):

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

See [`scripts/Publish-AvmAuthoring.ps1`](../../scripts/Publish-AvmAuthoring.ps1) for the end-to-end publish flow. It re-runs the same case-sensitive layout checks that the `layout` build task uses, so the local `./build.ps1 pre-commit` gate and the publish gate stay aligned.
