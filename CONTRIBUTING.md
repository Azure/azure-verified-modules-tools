# Contributing to `Avm.Authoring`

This module is being built up in phases per [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md). The engineering rules live in [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md) — read that before sending a PR.

The build, test, and lint scaffolding is live. The two things you most likely want:

- **Run the tests / local gate** — `./build.ps1 pre-commit` (layout + lint + unit tests). See [§6](#6-build-test-lint).
- **Install / run the module locally in dev mode** — `Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force`, then use the `avm` CLI from source. See [§3](#3-import-the-module-from-source).

---

## 1. Prerequisites

| Tool                                            | Minimum     | Required for                                       |
| ----------------------------------------------- | ----------- | -------------------------------------------------- |
| [PowerShell 7](https://aka.ms/powershell)       | 7.4 (LTS)   | Everything                                          |
| [Git](https://git-scm.com/downloads)            | 2.40        | Cloning, branching                                  |
| [Microsoft.PowerShell.PSResourceGet](https://learn.microsoft.com/powershell/utility-modules/psresourceget/overview) | 1.0.0 | Publishing (`Publish-PSResource`)                  |
| [Pester](https://pester.dev)                    | 5.5         | Running tests (`./build.ps1 test`)                  |
| [PSScriptAnalyzer](https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/overview) | 1.22        | Linting (`./build.ps1 lint`)                        |
| [Invoke-Build](https://github.com/nightroman/Invoke-Build) | 5.11        | Running `./build.ps1` tasks                         |
| [GitHub CLI](https://cli.github.com/)           | 2.40        | Optional — opening PRs from the terminal            |

Install everything the module needs (one-time, user scope):

```pwsh
Install-PSResource Microsoft.PowerShell.PSResourceGet -Scope CurrentUser
Install-PSResource Pester                              -Scope CurrentUser
Install-PSResource PSScriptAnalyzer                    -Scope CurrentUser
Install-PSResource InvokeBuild                         -Scope CurrentUser
```

PS 7.4 is required on **Windows**, **Linux**, and **macOS**. PS 5.1 is explicitly unsupported.

---

## 2. Clone the repo

```pwsh
git clone https://github.com/Azure/azure-verified-modules-tools.git
cd azure-verified-modules-tools
```

Use `Set-Location`, not relative `cd ../..`, when moving around the tree — paths in this guide assume the repo root is the current working directory.

---

## 3. Import the module from source

The simplest dev loop. No install, no copy, no symlink — point `Import-Module` at the manifest.

```pwsh
Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force
Get-Command -Module Avm.Authoring        # every exported verb + the `avm` alias
avm version                              # or: Get-AvmVersion
avm doctor                               # environment diagnosis
Remove-Module Avm.Authoring -Force
```

Re-run `Import-Module … -Force` after any change to `src/Avm.Authoring/*.ps*`.

`Remove-Module` before the next `-Force` import is good hygiene — it surfaces leaks (orphaned background jobs, registered event handlers, etc.) earlier.

---

## 4. Install the module into your user scope (from source)

For a closer-to-shipped experience without publishing, drop the module folder into your user module path.

### Find your user module path (cross-platform)

```pwsh
$userModulesPath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0]
$userModulesPath
```

Resolves to:

- **Windows**: `~/Documents/PowerShell/Modules`
- **Linux**: `~/.local/share/powershell/Modules`
- **macOS**: `~/.local/share/powershell/Modules`

### Copy in

```pwsh
$src   = Join-Path $PWD 'src/Avm.Authoring'
$dst   = Join-Path $userModulesPath 'Avm.Authoring'
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
Copy-Item $src $dst -Recurse
```

Now `Avm.Authoring` autoloads in any new PS 7 session: `Get-AvmAuthoringPlaceholder` just works.

To undo:

```pwsh
$userModulesPath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0]
Remove-Item (Join-Path $userModulesPath 'Avm.Authoring') -Recurse -Force
```

### Or symlink (advanced)

For an inner loop where edits in `src/` are picked up by a fresh shell without copying:

```pwsh
$userModulesPath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0]
$src = Join-Path $PWD 'src/Avm.Authoring'
$dst = Join-Path $userModulesPath 'Avm.Authoring'
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType SymbolicLink -Path $dst -Target $src
```

> **Windows**: creating a symlink needs either an elevated shell **or** Developer Mode enabled (Settings → System → For developers).

---

## 5. Validate the module layout

The post-incident layout check (`Test-AvmModuleLayout`, [spec §12](docs/avm-implementation-spec.md#12-module-manifest-rules-post-incident)) enforces that the on-disk folder / file / manifest casing matches `Avm.Authoring` exactly. Run it any time via the `layout` task (it's also the first step of `pre-commit` and `ci`):

```pwsh
./build.ps1 layout
```

Expected output:

```text
  layout OK: Avm.Authoring <version> (PS >= 7.4)
```

The publish script (`scripts/Publish-AvmAuthoring.ps1`) applies the same hard casing guards inline; run it in `-WhatIf` mode for a publish-path dry run:

```pwsh
./scripts/Publish-AvmAuthoring.ps1 -WhatIf
```

If either throws a casing error, the on-disk folder, file, or manifest casing has drifted from `Avm.Authoring` / `Avm.Authoring.psd1` / `Avm.Authoring.psm1`. Fix the casing on disk (rename the folder via `Move-Item` to a different name, then back to the correct one — see [spec §6.2](docs/avm-implementation-spec.md#case-sensitivity)) before retrying.

---

## 6. Build, test, lint

The Invoke-Build task graph lives at `build/avm.build.ps1`; always invoke it through the `./build.ps1 <task>` forwarder from the repo root. `pre-commit` is the gate to run before every PR.

```pwsh
./build.ps1 pre-commit        # layout + lint + unit tests — the local gate
./build.ps1 ci                # layout + lint + coverage + component (what CI runs)

# Individual tasks
./build.ps1 layout            # casing + manifest-shape guard (Test-AvmModuleLayout)
./build.ps1 lint              # PSScriptAnalyzer with repo settings + custom rules
./build.ps1 test              # Pester unit tests (excludes Component + Integration)
./build.ps1 coverage          # unit tests + coverage gate (fails below the 70% line floor)
./build.ps1 component         # Pester Component tier (real FS + real subprocess, stub binaries, no network)
./build.ps1 integration       # Pester Integration tier (real network + real binaries; not part of ci/pre-commit)
./build.ps1 build             # stage a publishable tree under ./out/Avm.Authoring + verify exports
./build.ps1 clean             # remove ./out
./build.ps1 ?                 # list every task
```

Notes:

- `test` runs the **unit** tier only. The `Component` and `Integration` tiers are separate tasks (and separate `-Tag`s) so routine local runs stay fast and offline.
- `integration` is the only task that touches the network (it also runs the real pinned binaries) and is deliberately excluded from `pre-commit` and `ci`; run it on demand.
- A first run installs nothing for you — make sure the prerequisites in [§1](#1-prerequisites) (InvokeBuild, Pester, PSScriptAnalyzer) are present.

---

## 7. Run a single Pester test

The test tree lives at `tests/Pester/{Unit,Component,Integration}/`. To run one file directly with Pester (bypassing the build task):

```pwsh
Invoke-Pester -Path ./tests/Pester/Unit/Public/Invoke-AvmPreCommit.Tests.ps1 -Output Detailed
```

To run one `It` / `Describe` block by name:

```pwsh
Invoke-Pester -Path ./tests/Pester/Unit -FullNameFilter '*Invoke-AvmPreCommit*'
```

Component and Integration tests are tagged, so target them with `-Tag`:

```pwsh
Invoke-Pester -Path ./tests/Pester/Component -Tag Component -Output Detailed
```

---

## 8. Publish to PSGallery (maintainers only)

Don't run this unless you're a PSGallery owner of the `Avm.Authoring` package and you intend to ship.

```pwsh
$key = Read-Host -AsSecureString -Prompt 'Paste your PSGallery API key (input is hidden)'
./scripts/Publish-AvmAuthoring.ps1 -ApiKey $key
Remove-Variable key
Remove-Item (Get-PSReadLineOption).HistorySavePath -Force  # clear the history file just in case
```

**Never** pass the API key as a positional argument to `Read-Host -Prompt` or paste it into the chat / commit message / shell history. The version of the script above is the only sanctioned publish path; it asserts the on-disk casing matches the manifest before calling `Publish-PSResource` ([spec §12](docs/avm-implementation-spec.md#12-module-manifest-rules-post-incident)).

---

## 9. OS-specific notes

### Windows

- Use PowerShell 7, not Windows PowerShell 5.1. `pwsh` not `powershell`.
- `Copy-Item` and `Move-Item` are case-preserving but not case-sensitive — renames within the same casing class are silent no-ops. To change a folder or file's casing, rename to a different name first and then to the desired casing.
- Symlinks need Developer Mode or an elevated shell.
- The module forces the console to UTF-8 at import time (`[Console]::OutputEncoding` + `$OutputEncoding`) so subprocess stdout/stderr from `terraform`, `bicep`, `tflint`, `conftest`, and friends decode cleanly. The default Windows console code page (1252, 437) mangles UTF-8 bytes. To opt out — for example, you've already configured the console deliberately for non-AVM tooling — set the environment variable **before** importing the module:

   ```pwsh
   $env:AVM_NO_CONSOLE_CONFIG = '1'
   Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force
   ```

   The opt-out is Windows-only — Linux and macOS use UTF-8 natively, so the module skips the encoding setup on those platforms regardless of `AVM_NO_CONSOLE_CONFIG`. The mechanism lives in `src/Avm.Authoring/Avm.Authoring.psm1` (top-of-file `if` block).

### Linux

- If you installed PS via the `dotnet tool` channel, `pwsh` lives under `~/.dotnet/tools/`. Add it to PATH.
- Filesystem is case-sensitive by default — code that breaks on Linux but not Windows is almost always a casing bug.

### macOS

- APFS is case-insensitive *but* case-preserving by default, like NTFS. The PSGallery casing trap from May 2026 reproduces here. Treat as case-sensitive.
- Apple Silicon is the Tier 1 target ([spec §2](docs/avm-implementation-spec.md#operating-systems)); Intel macs run but get smoke tests only in CI.

---

## 10. Branch and PR workflow

1. Fork the repo and create a feature branch off `main`:

   ```pwsh
   git switch -c feat/<short-description>
   ```

2. Make changes, keeping the PR focused on a single concern.
3. Run the local gate before pushing: `./build.ps1 pre-commit` (layout + lint + unit tests).
4. Commit. Prefer [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `chore:`).
5. Push and open a PR against `Azure/azure-verified-modules-tools:main`. Link the relevant phase / spec section in the description.
6. Address review comments via `git commit --fixup` + `git rebase -i --autosquash` before merge, not force-push reflinks.

---

## 11. What to read before changing anything

| Topic                                            | File                                                                 |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| Why the module exists and what we're building     | [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md)     |
| How to write spec-compliant code                  | [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md)   |
| Cross-cutting standards + traps to know about     | [docs/quality-standards.md](docs/quality-standards.md)               |
| Module placeholder details                         | [src/Avm.Authoring/README.md](src/Avm.Authoring/README.md)           |
| The casing incident (mandatory reading)            | [docs/avm-implementation-spec.md §12](docs/avm-implementation-spec.md#12-module-manifest-rules-post-incident) |
