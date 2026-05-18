# AVM Tooling Consolidation Plan

A phased plan to consolidate the Azure Verified Modules (AVM) tooling described in [avm-tooling-report.md](avm-tooling-report.md) behind a single CLI. The CLI lives in this repository, starts as a facade over today's tools, and selectively replaces them as the surface stabilises. Once proven, it replaces the existing tooling in [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules) and [Azure/avm-terraform-governance](https://github.com/Azure/avm-terraform-governance).

---

## 1. Goals and non-goals

### Goals

1. **One unified CLI** (working name: `avm`) with consistent verbs across Bicep and Terraform.
2. **Local-CI parity.** A contributor can run any check on their workstation with the same command the CI runner uses.
3. **No fleet-wide breakage during rollout.** Existing module repos and the Bicep monorepo keep working unmodified until they opt in.
4. **Reduced supply-chain surface.** Bring the most critical custom tooling under a single, versioned distribution channel that the AVM core team controls.
5. **Reuse what works.** Wrap the existing PowerShell scripts, Go binaries, PSRule rule packs, Conftest policies, and the Bicep/Terraform CLIs rather than rewriting them up-front.
6. **Single mental model.** Module authors should not need to know whether the underlying tool is PowerShell, Go, or .NET.
7. **Native local-first execution.** The CLI runs directly on a contributor's dev workstation (Windows, Linux, macOS). No container is required — including for Terraform work that today depends on `mcr.microsoft.com/azterraform`. The CLI bootstraps its own native dependencies (Terraform, TFLint, `terraform-docs`, Conftest, `avmfix`, `mapotf`, `grept`, …) on demand.

### Non-goals

1. Rewriting the deep tools (`avmfix`, `mapotf`, PSRule.Rules.Azure, Conftest/OPA policies) up-front.
2. Replacing GitHub Actions as the CI provider.
3. Changing the AVM module specifications themselves.
4. Migrating away from the Bicep CLI or the Terraform CLI.
5. Eliminating the Public Bicep Registry or the Terraform Registry.
6. Replacing GitHub OIDC for Azure authentication.
7. Maintaining the existing `mcr.microsoft.com/azterraform` container as the primary developer environment. It is explicitly deprecated; a minimal image may be published later for users who choose to run the CLI in a container, but it is never required.

---

## 2. Guiding principles

| Principle                              | What it means in practice                                                                          |
| -------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Local-CI parity is non-negotiable      | Every check is an Invoke-Build task; CI calls `./build.ps1 <task>`, contributors call the same.    |
| Opt-in adoption                        | Existing repos keep working. Adoption is per-repo, per-phase, controlled by a config file.        |
| Determinism                            | Tool versions pinned by version + SHA256 in a single `tools.lock.psd1` manifest; downloads verified before use; no runtime fetch of `main` branches. |
| Native, install-on-demand dependencies | The CLI never assumes Terraform, TFLint, `avmfix`, `mapotf`, `grept`, Conftest, or `terraform-docs` are pre-installed. It checks `PATH`, falls back to a per-user tool cache, and installs missing/outdated tools from the lock manifest. Works the same locally and in CI; no container needed. |
| Observability                          | Every task emits structured logs and a machine-readable summary suitable for GitHub annotations.    |
| Parallel coexistence                   | Existing `./avm`, `./avm.ps1`, `Makefile`, and `utilities/tools/*.ps1` entry points remain untouched in their current repos. Contributors install the new module alongside and test it directly. Phase 6 deletes the old entry points once adoption is broad. No shim layer exists at any point. |
| Boundary validation only               | Validate at the CLI boundary (verb args, repo detection); trust internal modules.                  |
| One source of truth per concern        | The AVM CSV stays the canonical module index; PSRule baselines stay canonical for Azure best practice. |

---

## 3. Architecture options

The CLI has to do three jobs: parse user input, decide what to run, and invoke the underlying tool. The three jobs can be implemented in different languages — the table below compares pure PowerShell, pure C#, and a hybrid.

### Option 1 — PowerShell module on PSGallery

| Aspect                  | Detail                                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------------- |
| Implementation          | PowerShell 7 module published to PSGallery. The module exports both a single `avm` dispatcher function (for verb-style use such as `avm pre-commit`) and idiomatic approved-verb cmdlets (`Invoke-AvmPreCommit`, `Test-AvmModule`, `Install-AvmTool`, …). PowerShell module auto-loading means `avm` is available in any fresh PS7 session after one-time `Install-Module Avm`. No repo-local shim file is required. |
| Bicep integration       | Native — most existing Bicep tooling is already PS; calls happen in-process                         |
| Terraform integration   | Shells out to `terraform`, `tflint`, `terraform-docs`, `conftest`, `avmfix`, `mapotf`, `grept`     |
| Orchestration           | Invoke-Build, native fit                                                                            |
| Distribution            | PSGallery, GitHub Releases zip                                                                      |
| Dependencies for users  | PowerShell 7                                                                                        |
| Strengths               | Lowest lift — reuses the 30+ existing PS scripts verbatim; PSRule SDK integration is trivial; Invoke-Build is idiomatic; cross-platform via PS 7 |
| Weaknesses              | Users without PS7 must install it; performance is bounded by PS7                                   |

### Option 2 — C# CLI (.NET 9 single-file)

| Aspect                  | Detail                                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------------- |
| Implementation          | Single self-contained native binary per OS (`avm.exe`, `avm`, `avm-osx`); System.CommandLine        |
| Bicep integration       | Shell out to `pwsh` for the existing PS scripts, or rewrite incrementally in C#                     |
| Terraform integration   | Shells out to the same Go binaries; could embed them via process invocation only                    |
| Orchestration           | Nuke.Build (C#) or hand-rolled task graph                                                            |
| Distribution            | GitHub Releases, `dotnet tool`, Homebrew tap, Scoop bucket                                          |
| Dependencies for users  | None (single binary)                                                                                |
| Strengths               | Best UX (`./avm <verb>` with no runtime); strong typing; one binary that mirrors the Terraform `./avm` UX |
| Weaknesses              | Massive rewrite cost — every PS script becomes a shell-out or a port; PSRule.Rules.Azure has no first-class .NET SDK; loses the natural fit between Invoke-Build and the Bicep scripts |

### Option 3 — Hybrid (C# front door, PowerShell engine, Go binaries as-is)

| Aspect                  | Detail                                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------------- |
| Implementation          | C# `avm` binary parses args and routes verbs; PowerShell module loaded in-process via the [PowerShell SDK (`Microsoft.PowerShell.SDK`)](https://learn.microsoft.com/powershell/scripting/developer/hosting/hosting-the-windows-powershell-engine) for Bicep work; Go binaries invoked as subprocesses for HCL transforms |
| Bicep integration       | Existing PS scripts run in-process (no `pwsh.exe` startup cost)                                     |
| Terraform integration   | Same as Option 2                                                                                    |
| Orchestration           | Invoke-Build tasks defined in PowerShell, executed by the hosted runspace                            |
| Distribution            | GitHub Releases (single binary), `dotnet tool`, plus a PSGallery module for direct PS use           |
| Dependencies for users  | None (single binary); PS7 optional for direct module use                                            |
| Strengths               | Best of both worlds — modern CLI UX without throwing away the PS investment; Spectre.Console for TUI; PSRule.Rules.Azure invocable via the hosted runspace |
| Weaknesses              | Hybrid stack is heavier to maintain; .NET → PowerShell SDK has its own quirks; build is more complex |

### Recommendation

**Start as Option 1, plan to evolve into Option 3.**

Concretely:

- **Phases 0–2** (facade): pure PowerShell module distributed via PSGallery. This is the fastest path to a working unified CLI that wraps both ecosystems and lets us validate the verb model on real workloads.
- **Phase 3 onwards** (selective replacement): introduce a C# front-end binary (Option 3) when (a) the verb surface is stable and (b) a polished single-binary UX has measurable value over the PS module. The PowerShell module continues to exist as the engine and as a directly consumable module on PSGallery.

We do **not** commit to Option 2 (pure C#) at any point — the cost of rewriting the Bicep PowerShell estate is not justified by the UX gain.

---

## 4. Unified CLI verb model

The CLI is one command with a small, stable verb surface. Each verb routes to a Bicep or Terraform implementation based on auto-detected repo context (`bicepconfig.json` and `avm/` folder vs `*.tf` files plus `terraform.tf`).

| Verb                          | Bicep behaviour                                                          | Terraform behaviour                                                        |
| ----------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| `avm new`                     | Scaffold new resource/pattern/utility module (replaces `Set-ModuleFileAndFolderSetup.ps1`) | Scaffold new module from `tfmod-scaffold` template                         |
| `avm format`                  | `bicep format` + Prettier                                                | `terraform fmt` + `avmfix`                                                 |
| `avm lint`                    | Bicep linter + ESLint + compliance Pester subset (fast checks)           | `tflint` with merged AVM config                                            |
| `avm check policy`            | PSRule.Rules.Azure                                                       | Conftest with APRL + AVMSEC                                                |
| `avm check convention`        | Compliance Pester suite (`module.tests.ps1`)                             | `grept run`                                                                |
| `avm transform`               | Regenerate README + test scaffolding (`Set-AVMModule`)                   | `mapotf transform` + clean-backup                                          |
| `avm docs`                    | `Set-ModuleReadMe.ps1`                                                   | `terraform-docs`                                                           |
| `avm test unit`               | Pester unit tests                                                        | `terraform test` against `tests/unit/`                                     |
| `avm test integration`        | ARM what-if via `Test-TemplateDeployment.ps1`                            | `terraform test` against `tests/integration/`                              |
| `avm test e2e`                | Actual deployment via `New-TemplateDeployment.ps1`                       | `terraform apply` per example via porch (Phase 0–2) or built-in (Phase 3+) |
| `avm pre-commit`              | Composition: `format` + `lint` + `transform` + `docs`                    | Composition: `format` + `transform` + `convention` + `validate` + `docs`   |
| `avm pr-check`                | Composition of every check that runs in CI                               | Composition of every check that runs in CI                                 |
| `avm publish`                 | `bicep publish` to Public Bicep Registry                                 | Tag-driven publish to Terraform Registry                                   |
| `avm release`                 | Update version.json + changelog + open PR                                | Update changelog + tag + open PR                                           |
| `avm index update`            | `Invoke-AvmJsonModuleIndexGeneration.ps1`                                | Update governance index entry                                              |
| `avm governance issue sync`   | `Set-AvmGitHubIssueForWorkflow` + owner config                           | Equivalent porting in Phase 5                                              |
| `avm governance pr label`     | `Set-AvmGitHubPrLabels`                                                  | Equivalent porting in Phase 5                                              |
| `avm governance workflow toggle` | `Switch-WorkflowState`                                                | Equivalent porting in Phase 5                                              |
| `avm tool list`               | List every tool in `tools.lock.psd1` with resolved path and version      | Same                                                                       |
| `avm tool install [<name>\|--all]` | Bootstrap a missing/outdated tool from the lock manifest into the user cache | Same                                                                |
| `avm tool which <name>`       | Print the resolved path the CLI would use for the given tool             | Same                                                                       |
| `avm doctor`                  | Diagnose: PS version, Bicep version, Az modules, OIDC config, tool-cache status | Diagnose: Terraform/TFLint/`terraform-docs`/Conftest/`avmfix`/`mapotf`/`grept` versions vs lock, OIDC; `--install` bootstraps anything missing |
| `avm version`                 | Print CLI version + each underlying tool's version                       | Same                                                                       |

Global flags: `--ecosystem bicep|terraform|auto` (default `auto`), `--module <path>`, `--json` (machine output), `--verbose`, `--dry-run`, `--auto-install` / `AVM_AUTO_INSTALL=1` (install any missing managed tool without prompting).

### Developer experience

The CLI ships as a PowerShell module on PSGallery. There is **no repo-local `./avm` or `./avm.ps1` script** in any new module or in this repo. The new module is developed and tested in parallel with the existing `./avm` scripts in upstream repos: a contributor who wants to try it runs `Install-Module Avm` and calls the new cmdlets directly, while the existing scripts continue to work unchanged for everyone else. Phase 6 deletes the old scripts once enough modules have moved over — there is no shim or deprecation-warning adapter at any point.

One-time setup:

```powershell
Install-Module Avm -Scope CurrentUser
```

Per-task workflow from any module folder:

```powershell
cd terraform-azurerm-avm-res-keyvault-vault    # or any Bicep module folder
avm pre-commit
avm test unit
avm publish
```

The `avm` command is an exported function of the module; PowerShell 7's module auto-loading resolves it on first use, so a fresh shell sees it immediately as long as the module is on `$env:PSModulePath`.

**Two equivalent surfaces** are exported from the same module, and a developer picks whichever style suits the task:

| Style                  | Example                                                                   | Best for                                                            |
| ---------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Verb dispatcher        | `avm pre-commit`, `avm test unit`, `avm tool install --all`              | Interactive use; muscle memory consistent with `./avm pre-commit`  |
| Approved-verb cmdlets  | `Invoke-AvmPreCommit`, `Test-AvmModule -Layer Unit`, `Install-AvmTool -All` | Scripting, pipelines, discoverability via `Get-Command -Module Avm` |

Both surfaces call the same single implementation per verb. Cmdlets are auto-generated from the verb registry so they stay in lock-step with the dispatcher.

The context resolver (§6) means commands work without explicit arguments when run from inside a module — `avm pre-commit` infers the module path, ecosystem, and scope from the current directory.

---

## 5. Repo / context resolver

A single discovery layer replaces both `Get-ModuleList.ps1` and Porch's example walker.

Detection rules:

1. **Bicep monorepo**: `bicepconfig.json` at root and `avm/{res,ptn,utl}/` folders present.
2. **Bicep module path**: any directory containing `main.bicep` and `version.json`.
3. **Terraform module repo**: `terraform.tf` plus `examples/` and `tests/` folders.
4. **Terraform module path**: any directory containing `*.tf` files and a matching `tests/` subtree.

The resolver returns a `ModuleContext` object (kind, root path, ecosystem, scope, owner). Every verb consumes this object so they all behave identically across explicit `--module` and auto-discovery.

---

## 6. Tool bootstrap and dependency management

The CLI is responsible for every non-PowerShell binary it needs. It never assumes a containerised environment and never relies on a contributor having already installed Terraform, TFLint, `terraform-docs`, Conftest, `avmfix`, `mapotf`, or `grept`.

### `tools.lock.psd1` manifest

A single manifest in the repo root pins each tool by version and per-OS SHA256:

```powershell
@{
    schemaVersion = 1
    tools = @(
        @{
            name        = 'terraform'
            version     = '1.9.5'
            urlTemplate = 'https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{os}_{arch}.zip'
            entrypoint  = 'terraform'
            sha256 = @{
                'windows-amd64' = '…'
                'linux-amd64'   = '…'
                'darwin-arm64'  = '…'
            }
        }
        @{ name = 'tflint';         version = '0.53.0';  … }
        @{ name = 'terraform-docs'; version = '0.19.0';  … }
        @{ name = 'conftest';       version = '0.56.0';  … }
        @{ name = 'avmfix';         version = 'v0.2.1';  … }
        @{ name = 'mapotf';         version = 'v0.4.0';  … }
        @{ name = 'grept';          version = 'v0.6.0';  … }
        @{ name = 'bicep';          version = '0.30.3';  … }
    )
}
```

### Resolution order

For every managed tool, on every invocation:

1. Look in the user-local tool cache:
   - Windows: `%LOCALAPPDATA%\avm\tools\<name>\<version>\`
   - Linux:   `$XDG_CACHE_HOME/avm/tools/<name>/<version>/` (default `~/.cache/avm/tools/`)
   - macOS:   `~/Library/Caches/avm/tools/<name>/<version>/`
2. Look on `PATH`; if found, verify the version matches the lock. If it matches, use it; if it doesn't, warn and fall back to the cache.
3. If nothing satisfies the lock, install on demand:
   - Interactive run: prompt the user once per session before downloading.
   - Non-interactive run (`--auto-install`, `AVM_AUTO_INSTALL=1`, or CI detected via `GITHUB_ACTIONS=true`): install silently.
4. Download from the manifest URL, verify the SHA256, unpack into the cache, mark executable, and use it.

The cache is per-user, never the repo, so multiple checkouts and CI jobs share the same downloads.

### Operator UX

- `avm doctor` reports each tool as `OK`, `Outdated`, or `Missing` with the resolved path, the version found, and the version required. `avm doctor --install` upgrades the workstation to lock.
- `avm tool install --all` is the recommended first command after `git clone` and the first step of every CI job.
- `avm tool which terraform` prints the exact binary that would be invoked — useful for debugging PATH shadowing.
- A user that already has a compatible Terraform on PATH is never forced to download a second copy.

### CI integration

The CI workflow runs `avm tool install --all` and caches the tool directory keyed on the SHA of `tools.lock.psd1`:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.cache/avm/tools
    key: avm-tools-${{ runner.os }}-${{ hashFiles('tools.lock.psd1') }}
- run: ./build.ps1 install-tools
- run: ./build.ps1 pr-check
```

No container is built, pulled, or run.

### Things the CLI does **not** install

A short list of dependencies remains user-provided because they are either standard developer tooling, OS-level, or auth-scoped:

- PowerShell 7 (the CLI's host runtime) — `avm doctor` detects the version and points to the install docs.
- `git`, `gh` (GitHub CLI), `az` (Azure CLI).
- .NET SDK (only required if Hybrid mode is activated in Phase 3+).

---

## 7. Phased delivery

Each phase is independently shippable. Phase boundaries are also natural checkpoints to demo to the AVM core team and reset priorities.

### Phase 0 — Skeleton

**Deliverables**

- Repo layout in this repo:

  ```text
  src/
    Avm/                       # PowerShell module (PSGallery package)
      Avm.psd1
      Avm.psm1
      Public/                  # exported cmdlets + the `avm` dispatcher function
      Private/                 # internal helpers + ModuleContext resolver
      Engines/Bicep/           # facade layer over utilities/tools PS scripts
      Engines/Terraform/       # facade layer over avmfix/mapotf/grept/terraform
  build/
    avm.build.ps1              # Invoke-Build task graph
    tasks/                     # per-area task scripts
  tests/
    Pester/                    # Pester tests for the CLI
    Integration/               # smoke tests that exercise the wrapped tools
  docs/                        # this folder
  .github/
    workflows/
      ci.yml                   # runs build/avm.build.ps1 tasks
      release.yml              # PSGallery + GH Release publishing
  ```

- Invoke-Build task graph with placeholders for every Phase 1 verb.
- `./build.ps1` entry point that forwards to Invoke-Build.
- CI workflow `.github/workflows/ci.yml` that runs the same tasks on Windows, Linux, and macOS runners.
- Distribution scaffolding: PSGallery publish job, GitHub Release zip job.
- Tool bootstrap subsystem (per §6): `tools.lock.psd1` manifest schema, per-user cache resolver, SHA256-verified downloader, and the `avm tool list|install|which` verbs.
- `avm doctor`, `avm version`, `avm tool *` (the only verbs that work in Phase 0).

**Exit criteria**: `./build.ps1 ci` runs the same tasks locally and in CI on all three OSes, with zero pre-installed tooling beyond PowerShell 7.

### Phase 1 — Bicep facade

**Deliverables**

- `avm` verbs `format`, `lint`, `check policy`, `check convention`, `transform`, `docs`, `test unit`, `test integration`, `pre-commit`, `pr-check`, `publish`, `index update` implemented as facades over:
  - `Set-AVMModule.ps1`, `Test-ModuleLocally.ps1`, `Set-ModuleReadMe.ps1`, `Set-EnvironmentOnAgent.ps1`, `Connect-AzAccountWithGitHubOidc.ps1`, `Invoke-AvmJsonModuleIndexGeneration.ps1`, `Publish-ModuleFromTagToPBR.ps1`.
  - Pester (compliance + unit tests).
  - `Invoke-PSRule -Module PSRule.Rules.Azure` (in-process call).
  - Bicep CLI (`bicep build|format|publish`).
- A fork of `Azure/bicep-registry-modules` that demonstrates the new verbs end-to-end on a handful of modules without changing existing CI.
- Migration guide for module authors: "instead of running `pwsh -File utilities/tools/Set-AVMModule.ps1 …`, run `avm transform …`".

**Exit criteria**: every Bicep workflow step that today calls a PowerShell script can be expressed as one or more `avm` verb invocations with identical behaviour.

### Phase 2 — Terraform facade

**Deliverables**

- `avm` verbs route to the Terraform stack:
  - `format` → `terraform fmt` + `avmfix`.
  - `lint` → `tflint` with merged AVM config (resolver picks `avm.tflint_module.hcl` vs `avm.tflint_example.hcl`).
  - `check policy` → `conftest test` with APRL + AVMSEC bundles.
  - `check convention` → `grept run`.
  - `transform` → `mapotf transform --mptf-dir … --tf-dir …` then `mapotf clean-backup`.
  - `docs` → `terraform-docs`.
  - `test unit` / `test integration` → `terraform test`.
  - `test e2e` → existing per-example apply via porch (delegated, not replaced).
- All Terraform-side native dependencies (`terraform`, `tflint`, `terraform-docs`, `conftest`, `avmfix`, `mapotf`, `grept`) added to `tools.lock.psd1` with verified SHA256s for Windows / Linux / macOS on amd64 and arm64.
- Primary UX is the module's exported `avm` function and approved-verb cmdlets per §4 — a developer runs `Install-Module Avm` once, then `cd` into any module and runs `avm pre-commit`. **No new repo ships a `./avm` file**, and this repo does not produce one. Existing `./avm` Bash and `./avm.ps1` scripts in upstream Terraform module repos are left untouched and keep working exactly as today; contributors trial the module side-by-side and we delete the old scripts in Phase 6.
- No container is built, pulled, or required. First-time invocations call `avm tool install --all` automatically when `--auto-install` or CI is detected.
- A pinned-asset feature: the CLI downloads governance assets (`mapotf-configs/`, `grept-policies/`, `tflint-configs/`, Conftest bundles) at a configurable ref (default `main` for backwards compatibility, overridable via `avm.config.json`).
- A demo on `Azure/terraform-azurerm-avm-res-keyvault-vault` (or a mock module) that runs the existing `pre-commit` / `pr-check` flow through the module on a bare Windows/Linux/macOS workstation — no `docker run mcr.microsoft.com/azterraform`, no repo-local script.

**Exit criteria**: a module author with only PowerShell 7 installed can `Install-Module Avm`, `cd` to a Terraform module, run `avm pre-commit`, and see the same results that today require the `azterraform` container and the repo-local `./avm` script — without touching the existing `./avm` script.

### Phase 3 — Replace `porch` orchestration

**Deliverables**

- Invoke-Build task definitions for every Porch pipeline currently in `porch-configs/`:
  - `pre-commit.porch.yaml` → `Build/Tasks/PreCommit.ps1`.
  - `pr-check.porch.yaml` → `Build/Tasks/PrCheck.ps1`.
  - `test-examples.porch.yaml` → `Build/Tasks/TestExamples.ps1`.
  - `terraform-test.porch.yaml` → `Build/Tasks/TerraformTest.ps1`.
  - `global-setup` / `global-teardown` → matching tasks.
- Per-example pre/post-hook engine (`pre.sh`/`pre.ps1`/`post.sh`/`post.ps1`, plus `.env` sourcing) reimplemented inside the CLI.
- TUI replacement via [Spectre.Console](https://spectreconsole.net/) (if Hybrid kicks in) or [PoshGui-like progress UI](https://github.com/PoshCode/Pester) in pure PS for now.
- `avm` retains a `--use-porch` flag that forces the legacy path for one release for safety.

**Exit criteria**: any module repo can remove its `Makefile` and `porch-configs` dependency and rely solely on the CLI, with identical behaviour.

### Phase 4 — Replace simple `mapotf` and `grept` rules

**Deliverables**

- Native PowerShell (and later C#) implementations of the rules whose logic is simple:
  - `required_provider_versions.mptf.hcl` → a small HCL-edit helper that updates `terraform.tf`'s `required_providers` block.
  - `outputs_tf.grept.hcl`, `variables_tf.grept.hcl` → file rename helpers.
  - `git_ignore.grept.hcl` → idempotent `.gitignore` enforcement.
  - `ensure_file_existence.grept.hcl`, `ensure_dir_existence.grept.hcl`, `deprecated_files.grept.hcl` → file presence helpers.
- Complex transforms stay on the Go binaries:
  - `main_telemetry_tf.mptf.hcl` (telemetry injection) — requires deep HCL editing.
  - `avm_headers_for_azapi.mptf.hcl` (AzAPI header rewrite) — same.
- A rule registry inside the CLI so authors can drop a `*.avmrule.psd1` or `*.avmrule.cs` into a folder and have it loaded automatically.

**Exit criteria**: at least half of today's `mapotf` and `grept` rule files are implemented natively; the rest run via the Go binaries through the same registry.

### Phase 5 — Consolidate governance scripts

**Deliverables**

- New `avm governance` verb tree backed by the existing PowerShell governance scripts:
  - `avm governance issue sync` → `Set-AvmGitHubIssueForWorkflow` + `Set-AvmGitHubIssueOwnerConfig`.
  - `avm governance pr label` → `Set-AvmGitHubPrLabels`.
  - `avm governance workflow rerun` → `Invoke-WorkflowsFailedJobsReRun`.
  - `avm governance workflow trigger` → `Invoke-WorkflowsForBranch`.
  - `avm governance workflow toggle` → `Switch-WorkflowState`.
  - `avm governance reaper run` → port of `tf-repo-mgmt/reaper/ReaperScript.ps1`.
- A unified `GitHubClient` helper that replaces the per-script REST calls (`Get-GitHubModuleWorkflowList`, `Get-GitHubIssueList`, …).
- AVM CSV stays the canonical source of truth; the CLI's `Get-AvmCsv` cmdlet wraps it.

**Exit criteria**: every `platform.*.yml` workflow can be expressed as `pwsh -c "avm governance …"` instead of `pwsh -File utilities/pipelines/platform/…`.

### Phase 6 — Upstream promotion

**Deliverables**

- PR to [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules):
  - Switch composite actions (`.github/actions/templates/avm-*`) and workflows to invoke `avm` verbs instead of `pwsh -File utilities/tools/*.ps1`.
  - Delete the legacy `utilities/tools/*.ps1` entry-point scripts once no workflow or composite action references them. The module continues to call the same underlying engines internally.
- PR to [Azure/avm-terraform-governance](https://github.com/Azure/avm-terraform-governance):
  - **Delete** `./avm` (Bash), `./avm.ps1`, and `Makefile`. There is no replacement shim — contributors run `Install-Module Avm` and call `avm <verb>` from any module folder.
  - Move `porch-configs/`, `mapotf-configs/`, `grept-policies/` under a `legacy/` folder, retained read-only for historical reference.
- PR to every Terraform module repo (templated, automated): **delete** `./avm`, `./avm.ps1`, and `Makefile`; add a one-line `README` note pointing at `Install-Module Avm`.
- A migration document at `docs/legacy-tooling.md` in each upstream repo that lists every removed script and its new `avm` verb equivalent.
- **Container retirement.** The `mcr.microsoft.com/azterraform:avm-*` image is marked deprecated in `Azure/avm-terraform-governance` `README.md`. The Dockerfile and `azterraform` build pipeline are moved to a `legacy/` folder with a notice that the CLI runs natively. Any contributor or CI job that still wants a container can `docker run mcr.microsoft.com/powershell:lts-7.4-ubuntu-22.04 pwsh -c 'Install-Module Avm; avm …'`, but no first-class image is maintained.

**Exit criteria**: both upstream repos build and pass CI using the module exclusively, on standard GitHub-hosted runners with no container step and no repo-local entry-point scripts. No shims remain because none were ever introduced.

---

## 8. Local-CI parity strategy

| Concern             | Approach                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Single entry point  | Both contributors and CI invoke `./build.ps1 <task>` (or `avm <verb>` after Phase 1).                                     |
| Identical tool versions | Pinned in `tools.lock.psd1`; the same manifest drives local installs and CI installs (see §6). CI fails if a resolved tool version doesn't match the lock. |
| Identical environment | CLI exposes `avm env --print` to dump every relevant env var; CI uses the same dump.                                    |
| Idempotency         | Tasks are designed to be safe to re-run; no implicit state between runs.                                                  |
| Output parity       | Same JSON / annotation output locally and in CI; CI just renders the annotations differently.                              |
| No container divergence | The same native binaries (resolved by the bootstrap subsystem) run locally and in CI — there is no second runtime to drift from. |

---

## 9. Backward compatibility

The migration is built on **parallel coexistence**, not in-place replacement. The new module is published to PSGallery and developed in this repo. Every legacy entry point listed below keeps working exactly as today — unchanged — until Phase 6 deletes it. A contributor who wants to try the new flow runs `Install-Module Avm` and calls the new cmdlets directly; everyone else carries on with the existing scripts. There is no shim layer and no deprecation-warning adapter.

| Legacy entry point                                                | New entry point                       | Coexistence story                            |
| ----------------------------------------------------------------- | ------------------------------------- | ----------------------------------------- |
| `pwsh -File utilities/tools/Set-AVMModule.ps1 -ModuleFolderPath …` | `avm transform --module …`            | Script stays in place and continues to work. Phase 6 PR switches workflows and composite actions to `avm` and deletes the script. |
| `pwsh -File utilities/tools/Test-ModuleLocally.ps1 …`              | `avm test unit|integration|e2e …`     | Same. |
| `./avm pre-commit` (Bash, expects `azterraform` container on PATH) | `Install-Module Avm` once, then `avm pre-commit` from any module folder | The `./avm` Bash script and the container are left untouched in upstream Terraform module repos. Contributors can run either path. Phase 6 deletes `./avm` and retires the container. |
| `./avm.ps1 pre-commit`                                            | `avm pre-commit` (exported by the PSGallery module) | Same; `./avm.ps1` is deleted in Phase 6. |
| `make pr-check`                                                   | `avm pr-check`                        | `Makefile` is left untouched until Phase 6 deletes it. |
| `porch run -f pre-commit.porch.yaml`                              | `avm pre-commit`                      | Optional `--use-porch` flag inside the new module preserves the legacy execution path for one release after Phase 3 — this is an internal fallback in the new code, not a shim over the old `./avm`. |
| `docker run mcr.microsoft.com/azterraform:avm-latest …`           | `avm …` directly on host              | Container is deprecated in Phase 6; users who insist on a container can run the CLI inside any PS7-capable image. |

Removal policy: legacy entry points stay in their repos, untouched, until the Phase 6 PRs delete them. Because the new module is installed and called directly rather than replacing the old scripts in place, there is nothing to keep alive "for one release" — either a repo is on the new module or it is still on the old script, never both at the same call site.

---

## 10. Distribution and versioning

| Channel                | Phase available | Purpose                                                                |
| ---------------------- | --------------- | ---------------------------------------------------------------------- |
| PSGallery              | Phase 0         | Primary distribution; one `Install-Module Avm` and you're done         |
| GitHub Releases (zip)  | Phase 0         | Air-gapped / firewalled environments                                   |
| `dotnet tool`          | Phase 3+        | Only if Option 3 (Hybrid) is activated                                 |
| Homebrew tap, Scoop bucket | Phase 3+    | Convenience for macOS / Windows users (Hybrid path only)               |

There is intentionally **no container distribution channel**. The Terraform-side `azterraform` image is retired in Phase 6. Anyone who wants a container can run the CLI inside any PowerShell 7 base image — the CLI bootstraps the rest.

Versioning: SemVer, one stable minor per quarter, weekly preview tags off `main`. Breaking changes only at minor bumps, never at patch.

---

## 11. Risks and mitigations

| Risk                                                                   | Likelihood | Impact | Mitigation                                                                                                          |
| ---------------------------------------------------------------------- | ---------- | ------ | ------------------------------------------------------------------------------------------------------------------- |
| Supply chain — `avmfix` and `porch` live on personal GitHub accounts   | Medium     | High   | During Phase 2, fork both into `Azure/*`; pin versions by SHA in `tools.lock.psd1`; offer to replace `porch` in Phase 3 |
| Governance asset drift — module repos pull configs from `main` at runtime | High    | High   | Phase 2 introduces ref-pinning; Phase 6 migrates everyone to the pinned defaults                                    |
| PSRule rewrites — no first-class .NET SDK                              | Medium     | Medium | Keep PSRule.Rules.Azure in-process via PowerShell SDK in Phase 3+; never rewrite                                    |
| Two-ecosystem cognitive load                                            | Medium     | Medium | Strict verb model + ecosystem-agnostic context resolver enforce uniform UX                                          |
| Tool download from public mirrors fails in restricted networks         | Medium     | Medium | `avm tool install` supports a `--mirror <url>` override and an offline mode that points at a local cache populated by an admin |
| Tool-cache corruption / partial download                               | Low        | Low    | Atomic extract + SHA256 verify; `avm tool install --force` re-downloads; cache layout is per-version so concurrent runs don't collide |
| Authentication parity                                                  | Low        | Medium | Both ecosystems already use GitHub OIDC — only the helper code needs unifying                                       |
| Adoption stalls (modules opt out)                                      | Medium     | High   | Parallel coexistence keeps every legacy entry point working unchanged until Phase 6, so trying the module is risk-free. Run the module side-by-side with `./avm` in upstream CI during the transition for confidence; only delete the legacy scripts in Phase 6 once a measurable share of modules has moved over. |
| Rewriting `mapotf` complex rules                                       | Medium     | Medium | Phase 4 explicitly scopes only the simple rules; complex transforms stay on the Go binary indefinitely if needed     |
| Windows / macOS / Linux behaviour drift                                | Low        | Medium | CI matrix from Phase 0 runs every task on all three OSes; same bootstrapped binaries everywhere                     |
| Loss of the curated `azterraform` image as a known-good environment    | Medium     | Medium | `avm doctor` reproduces the same guarantees by version-checking every managed binary against `tools.lock.psd1`; an opt-in `Dockerfile.dev` is provided as a convenience for users who still want a one-shot environment |

---

## 12. Open questions

1. **Terraform Registry publishing details.** Today this is a Git-tag-driven flow; the exact governance scripts that wire tags to Registry entries were not fully verified during research and need a dedicated review before Phase 2.
2. **Fork strategy for `lonegunmanb/avmfix` and `matt-FFFFFF/porch`.** Should the AVM team fork into `Azure/*` proactively in Phase 2, or only if the upstream maintainers become unresponsive?
3. **Default tool-cache location override.** Should `avm` honour a single env var (`AVM_TOOLS_DIR`) or follow per-tool overrides (`TF_INSTALL_DIR`, etc.) for users who already manage these binaries with `mise` / `asdf` / `tenv`?
4. **`dotnet tool` distribution.** Adopt now (as part of Phase 0) for future-proofing, or wait until Option 3 is on the roadmap?
5. **Telemetry.** Should the CLI emit anonymised usage telemetry to help the AVM team understand adoption, and if so what's the opt-out story?
6. **Compliance Pester suite.** It is ~500 lines and tightly coupled to the monorepo layout. Does it get ported to the CLI as a unit, or broken into individual `avm check convention` rules during Phase 1?
7. **Reaper script.** The Azure Automation runbook is the only piece that intentionally runs outside GitHub Actions today. Does it stay as a runbook calling `avm governance reaper run`, or move into a scheduled GitHub Action?

---

## 13. Phase summary

| Phase | Theme                                | Length signal*       | Key exit criterion                                                                  |
| ----- | ------------------------------------ | -------------------- | ----------------------------------------------------------------------------------- |
| 0     | Skeleton + parity-by-construction CI | Smallest             | `./build.ps1 ci` green on Win/Linux/macOS                                           |
| 1     | Bicep facade                          | Small                | All Bicep workflow steps expressible as `avm` verbs                                  |
| 2     | Terraform facade                      | Medium               | `avm pre-commit` replaces `./avm pre-commit` in a real module                       |
| 3     | Replace `porch`                       | Medium               | Module repo can drop `Makefile` + `porch-configs` dependency                        |
| 4     | Selective `mapotf` / `grept` port     | Small                | Half of today's HCL rules are native; rest still call Go binaries                   |
| 5     | Governance script consolidation       | Small                | All `platform.*` workflows invoke `avm governance …`                                 |
| 6     | Upstream promotion                    | Largest (review)     | Both upstream repos build on the module; legacy `./avm` scripts, `Makefile`s, and the container are deleted |

*Length signals are relative effort, not calendar estimates.

---

## 14. References

- Inventory: [avm-tooling-report.md](avm-tooling-report.md)
- Bicep monorepo: [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules)
- Terraform governance: [Azure/avm-terraform-governance](https://github.com/Azure/avm-terraform-governance)
- AVM specifications: [azure.github.io/Azure-Verified-Modules](https://azure.github.io/Azure-Verified-Modules/)
- Invoke-Build: [github.com/nightroman/Invoke-Build](https://github.com/nightroman/Invoke-Build)
- PSRule.Rules.Azure: [github.com/Azure/PSRule.Rules.Azure](https://github.com/Azure/PSRule.Rules.Azure)
- `avmfix`: [github.com/lonegunmanb/avmfix](https://github.com/lonegunmanb/avmfix)
- `porch`: [github.com/matt-FFFFFF/porch](https://github.com/matt-FFFFFF/porch)
- `mapotf`: [github.com/Azure/mapotf](https://github.com/Azure/mapotf)
- `grept`: [github.com/Azure/grept](https://github.com/Azure/grept)
- `tfmod-scaffold`: [github.com/Azure/tfmod-scaffold](https://github.com/Azure/tfmod-scaffold)
- AVM policy library: [github.com/Azure/policy-library-avm](https://github.com/Azure/policy-library-avm)
