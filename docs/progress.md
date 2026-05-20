# AVM CLI — Progress Checklist

Single source of truth for what's done, what's in flight, and what's next on the `Avm.Authoring` module. Read this first when picking up the work. Update it the moment you complete a meaningful slice — protocol in [AGENTS.md](../AGENTS.md).

**Last updated**: 2026-05-20 (SFI hardening: workflow actions SHA-pinned, Dependabot enabled for github-actions ecosystem, spec preamble elevates security to top non-functional priority)
**Active branch**: `feat/avm-authoring-initial` (pushed to `origin`, no PR yet)
**Working commit**: `7755de9 — WIP: initial Avm.Authoring module scaffold and CI`

## Snapshot

| Phase | Theme                       | Status                                                                                   |
| ----- | --------------------------- | ---------------------------------------------------------------------------------------- |
| 0     | Skeleton + parity CI        | **Complete** — every Phase 0 closure slice has landed: `layout`, `lint`, `test`, `coverage`, `integration`, `build`, `smoke` all green; release pipeline ready; spec §6.2 case-collision canary added (Linux-only). 241 unit tests pass + 5 Linux-only skip on Windows + 3 integration tests + 1 smoke test, 78.83% line coverage vs 70% floor, `build` task verifies 12 functions + 1 alias against the staged manifest |
| 1     | Bicep facade                | **Inner-loop scaffolded** — `format`/`lint`/`test` engines wired; heavy verbs not started |
| 2     | Terraform facade            | **Inner-loop scaffolded** — `format`/`lint`/`test`/`docs` engines wired; pre-commit suite not started |
| 3     | Replace `porch`             | Not started                                                                              |
| 4     | Selective `mapotf`/`grept`  | Not started                                                                              |
| 5     | Governance script port      | Not started                                                                              |
| 6     | Upstream promotion          | Not started                                                                              |

## Known issues / active blockers

- **Branch is `feat/avm-authoring-initial` but the work is broader** than the initial "scaffold" — consider an interim commit and a clearer PR-ready branch name when the next milestone lands.
- _(Mitigated 2026-05-20)_ `Invoke-ScriptAnalyzer` occasionally throws `NullReferenceException` from inside its own rule pipeline (no file/line in our code named). Observed on both `windows-latest` (run 26156193662, commit `bd778fd`) and `ubuntu-latest` (run 26156731288, commit `dc5b7f0`); re-run of the same commit always passes. Cause: a transient race in PSSA's rule-discovery / settings-hydration path. Mitigation: `build/avm.build.ps1` now wraps `Invoke-ScriptAnalyzer` in `script:Invoke-ScriptAnalyzerWithRetry`, which retries up to `AVM_LINT_MAX_ATTEMPTS` (default 3) times when, and only when, the caught exception (or any `InnerException`) is a `NullReferenceException` or carries the `Object reference not set to an instance of an object` message. Real findings come back as `DiagnosticRecord` objects and never trigger a retry. Each retry emits a `Write-Warning` so flakes remain visible in build logs.
- _(Resolved 2026-05-18)_ The PSScriptAnalyzer crash from the prior session no longer reproduces. `./build.ps1 lint` returns `lint OK: no findings`; full `pre-commit` is green (199 tests pass, 2 platform-conditional skips on Windows). Suspect cause: stale analyzer cache or transient state from an in-progress edit when the prior session was interrupted. If it reappears, bisect by running `Invoke-ScriptAnalyzer` per file under `src/Avm.Authoring/`.

## How to use this file

- Mark `[~]` when you start an item so the next session knows it's in flight.
- Flip `[~]` to `[x]` only after the work passes its own tests and the relevant `./build.ps1` task is still green (or the failure is documented).
- Add new must-do items under the right phase as you discover them; don't reshape historical items.
- When you hit a blocker you can't unstick this turn, add a bullet to **Known issues** with a one-line diagnosis.
- Always bump the **Last updated** line at the top.
- Never delete completed items — they are the audit trail.
- **Commit and push after every slice.** Once `./build.ps1 pre-commit` is green, `git add -A`, write a Conventional-Commits message, commit, and `git push origin feat/avm-authoring-initial`. Full rules live in `AGENTS.md` § **Commit & push protocol**.

---

## Phase 0 — Skeleton

### Repo + tooling

- [x] Repo layout (`src/Avm.Authoring/`, `tests/Pester/`, `build/`, `scripts/`, `docs/`, `.github/workflows/`)
- [x] `.gitattributes` enforcing LF + UTF-8 for every text type
- [x] `.gitignore`
- [x] `LICENSE` (MIT) referenced by manifest `LicenseUri`
- [x] `README.md` pointing at plan, spec, contributing guide
- [x] `CONTRIBUTING.md` (dev loop, install path, publish process, OS notes)
- [x] `docs/avm-consolidation-plan.md`
- [x] `docs/avm-implementation-spec.md`
- [x] `docs/avm-tooling-report.md`
- [x] `docs/progress.md` (this file) — created 2026-05-18
- [x] `AGENTS.md` agent protocol — created 2026-05-18
- [x] `.github/copilot-instructions.md` Copilot-specific pointer — created 2026-05-18

### Module + manifest

- [x] `Avm.Authoring.psd1` with locked casing, approved verbs, `PowerShellVersion = '7.4'`, `CompatiblePSEditions = @('Core')`
- [x] `Avm.Authoring.psm1` Public/Private/Engines auto-loader with UTF-8 console config on Windows (`AVM_NO_CONSOLE_CONFIG` opt-out)
- [x] `Resources/PSScriptAnalyzerSettings.psd1`
- [x] `Resources/tools.lock.psd1` populated with `bicep`, `terraform`, `terraform-docs`, `tflint`
- [x] `Test-AvmModuleLayout` post-incident casing guard (Private/Layout/) + tests
- [x] `Get-AvmAuthoringPlaceholder` back-compat shim retained from 0.0.1

### Cross-OS foundations

- [x] `Get-AvmFolder` (Config/Cache/Data/State/Tools/Logs) with `AVM_HOME` override + XDG + Windows Known Folders + macOS conventions + tests
- [x] Exception hierarchy (`AvmException`, `AvmConfigurationException`, `AvmToolException`, `AvmProcessException`, `AvmContextException`) with stable error codes + tests
- [x] `Invoke-AvmHttp` with TLS 1.2/1.3, SHA256 verify, `AVM_OFFLINE`, file:// fixture support, partial-file cleanup on hash mismatch + tests
- [x] `Invoke-AvmProcess` subprocess wrapper (argv arrays, stdout/stderr split, timeout, EnvVars override, IgnoreExitCode) + tests
- [x] `Get-AvmToolPlatform` returning normalised `<os>-<arch>` + tests
- [x] `Find-AvmToolOnPath` PATH probe with version-match reporting + tests

### Tool resolver + cache (`avm tool *`)

- [x] `Read-AvmToolsLock` (parses + validates lock at load time)
- [x] `Test-AvmToolsLock` schema validator (`schemaVersion`, https-only URLs, platform sha256 coverage, archives + platformAliases) + tests
- [x] `Resolve-AvmTool` (cache → PATH fallback under `-AllowPathFallback` → throw `AVM1014`) + tests
- [x] `Lock-AvmToolCache` cross-process file lock
- [x] `Expand-AvmToolArchive` (zip / tar.gz / raw)
- [x] `Install-AvmToolFromLock` (atomic stage → SHA verify → rename, `.verified` marker, `.meta.json`)
- [x] `Install-AvmTool` public verb (Force reinstall, `platformAliases`, tamper detection) + tests
- [x] `Get-AvmTool` public verb (list + which) + tests

### Dispatcher + introspection

- [x] `Get-AvmVerbRegistry` single source of truth for verb routing
- [x] `Invoke-Avm` dispatcher (alias `avm`, kebab-case flag → PascalCase param coercion, help when called bare, unknown-verb error) + tests
- [x] `Get-AvmVersion` + `avm version` route + tests
- [x] `Invoke-AvmDoctor` (PS version + edition + OS + writable folder probes) + tests
- [x] `.avm/.disable` sentinel + dispatcher refuses to run when present + tests
- [x] `Get-AvmModuleContext` (bicep monorepo / bicep module / terraform module repo / terraform module path, `.avm/context.psd1` override, `-Ecosystem` filter, repo-root vs module-path priority) + tests

### Build + CI

- [x] `build.ps1` repo-root entry forwarding to Invoke-Build
- [x] `build/avm.build.ps1` task graph: `layout`, `lint`, `test`, `coverage`, `build`, `clean`, `pre-commit`, `ci`
- [x] `.github/workflows/ci.yml` matrix on `ubuntu-latest`, `windows-latest`, `macos-latest`
- [x] **PSScriptAnalyzer crash diagnosis** — could not reproduce on 2026-05-18; `./build.ps1 lint` returns `lint OK: no findings`. Watching for recurrence on CI.
- [x] `coverage` task enforces the spec §18 70% line floor as a hard build gate (CI runs `layout + lint + coverage`; current actual 78.83%)
- [x] `build` task produces a tested staged module under `out/Avm.Authoring/` — in addition to `Test-ModuleManifest`, the task now spawns a fresh child `pwsh` to `Import-Module` the staged manifest and asserts every name in `FunctionsToExport` / `AliasesToExport` is actually reachable on the imported module (and nothing extra leaks out). The `avm` alias is also verified to resolve to `Invoke-Avm`. Failure mode produces an actionable message listing the missing/extra exports; success reports `build OK: <path> (<N> functions, <M> aliases verified)`. Helper lives next to `script:Assert-Module` in `build/avm.build.ps1` as `script:Test-AvmStagedModuleExports`

### Publish / release

- [x] `scripts/Publish-AvmAuthoring.ps1` (PSGallery publish path with hard casing guards, `-WhatIf` support)
- [x] `scripts/Update-AvmToolsLock.ps1` (refresh per-platform SHA256s for managed tools)
- [x] `.github/workflows/release.yml` (PSGallery publish on tag + GitHub Release zip with `SHA256SUMS`) — tag-driven (`v[0-9]+.[0-9]+.[0-9]+`) + `workflow_dispatch`; runs ci gate, `./build.ps1 build`, packages `out/Avm.Authoring-<version>.zip` + `out/SHA256SUMS`, verifies tag↔manifest↔CHANGELOG version match, publishes via `scripts/Publish-AvmAuthoring.ps1` (gated by `psgallery` environment + `PSGALLERY_API_KEY` secret), creates GitHub Release via `gh` CLI. Prerelease tags (`-preview.N` / `-rc.N`) deferred — the workflow currently rejects them with a clear error
- [x] `CHANGELOG.md` (Keep a Changelog format) with an unreleased section — `[Unreleased]` + `[0.1.0] - 2026-05-18` + `[0.0.1] - 2026-05-12` plus compare-URL refs; new `scripts/Get-AvmReleaseNotes.ps1` extracts the per-version section by exact `## [<version>]` match (rejects similarly-prefixed versions like `0.1.0` vs `0.1.0-preview.1`) and the release workflow fails before the ci gate if the entry is missing. 11 unit tests cover happy path + failure cases + CRLF tolerance + repo-CHANGELOG sanity

### Verbs that still owe Phase 0

- [x] `avm doctor --install` (auto-install every managed tool; `SupportsShouldProcess`, per-tool `Install-AvmToolFromLock`, `AVM1012` → Skip, optional `-Force`/`-LockPath`/`-AllowFileUrls`; 14 new tests)
- [x] `AVM_MIRROR` host-rewrite path through `Invoke-AvmHttp` — extracted into pure helper `Resolve-AvmMirrorUrl` (Private/Tools/). Preserves mirror scheme + authority + path prefix (e.g. `https://m.example.com/proxy` rewrites `https://releases.hashicorp.com/terraform/1.9.5/foo.zip` to `https://m.example.com/proxy/terraform/1.9.5/foo.zip`); rejects non-https mirrors with `AvmConfigurationException` so a misconfigured proxy can't silently downgrade TLS; never rewrites `file://` fixtures. 11 helper tests + 3 wire-through tests in `Invoke-AvmHttp.Tests.ps1`. Spec §10 and `tools.lock.psd1` header updated to document the contract.

### Test infrastructure

- [x] Pester 5.5+ Unit tests for every Public + Private function landed so far (230 pass, 2 skip on non-host OS)
- [x] Test tree mirrors source tree under `tests/Pester/Unit/{Module,Public,Private,Private/Engines}/`
- [x] `tests/Pester/Integration/` populated (spec §18 layer: real FS + stub binaries under `tests/fixtures/bin/`) — canary `Process.Tests.ps1` exercises `Invoke-AvmProcess` end-to-end against real `pwsh` subprocesses and real `TestDrive` filesystem (3 tests, all `-Tag Integration`); new `integration` build task wired into `ci` so the composite now runs `layout + lint + coverage + integration` per spec §18 "Every PR runs Unit + Integration"; `tests/fixtures/bin/README.md` documents the stub-binary harness convention for future engine-level integration tests that need to fake `bicep` / `terraform` / `tflint` / `terraform-docs`
- [x] `tests/Pester/Smoke/` populated (network-dependent, `-Tag Smoke`, run on release branches only) — canary `Http.Tests.ps1` downloads the smallest managed tool (`terraform-docs`, ~5 MB) from its real GitHub release via `Invoke-AvmHttp` and lets the helper's SHA verification catch any lock-file drift; the test is filed under `-Tag 'Smoke'`, inline-skips when `$env:AVM_OFFLINE='1'` (Pester 5 evaluates `-Skip:` at discovery time so the offline check has to be inline, not in `BeforeAll`), and writes into `TestDrive` so smoke runs leave no residue. New `smoke` build task mirrors the `integration` shape but stays out of both `pre-commit` and `ci` — it only runs when explicitly invoked via `./build.ps1 smoke`. README under `tests/Pester/Smoke/` documents the contract (real network, release-only, every test `-Tag 'Smoke'`, honour `AVM_OFFLINE`)
- [x] `tests/fixtures/` with a real case-collision file pair (spec §6.2) — only meaningful on Linux runners. Implemented as `tests/Pester/Unit/Private/CaseCollision.Tests.ps1` (5 tests, whole `Describe` `-Skip:(-not $IsLinux)` so it skips cleanly on Windows / macOS-default APFS). Two contexts: (a) raw filesystem behaviour proves Linux can host `Foo.txt` + `foo.txt` with different content and that `Get-ChildItem | Where -ceq` reliably picks the requested casing; (b) the `Test-AvmModuleLayout` resolver is pointed at a fake module that *deliberately* contains both `Avm.Authoring.psd1` + `avm.authoring.psd1` (and matching `.psm1`s) in the same directory — the test asserts the resolver still loads the correctly cased manifest, guarding against any regression to `-eq` or to a silent wrong-file pick
- [x] Encoding/EOL pre-commit Pester check (spec §5: "no BOM, no CRLF in `src/`") — `tests/Pester/Unit/Module/Encoding.Tests.ps1` walks every `.ps1`/`.psm1`/`.psd1`/`.md`/`.yml`/`.yaml`/`.json`/`.toml`/`.sh`/`.bicep`/`.tf` under `src/` and asserts no UTF-8 BOM (bytes 0xEF 0xBB 0xBF) and no 0x0D byte. Caught a real CRLF in `Resolve-AvmMirrorUrl.ps1` on first run (file-write tooling defaulted to Windows endings); fixed and now green.

---

## Phase 1 — Bicep facade

### Already in place (scaffolding)

- [x] `Invoke-AvmFormat` public verb + `Format-AvmBicepModule` engine (`bicep format` per file) + tests
- [x] `Invoke-AvmLint` public verb + `Invoke-AvmBicepLint` engine (`bicep lint <file> --diagnostics-format defaultV2`, parsed into Issue records) + tests
- [x] `Invoke-AvmTest` public verb + `Invoke-AvmBicepTest` engine (`bicep build --stdout` per file) + tests
- [x] `Invoke-AvmDocs` public verb (Bicep engine returns a clear `AvmConfigurationException` until the ARM-JSON walker lands) + tests
- [x] `Invoke-AvmTransform` public verb + `Invoke-AvmBicepTransform` engine stub (throws `AvmConfigurationException` until the `Set-AVMModule.ps1` replacement lands) + tests; verb registry route `avm transform`
- [x] `Invoke-AvmCheckPolicy` public verb + `Invoke-AvmBicepCheckPolicy` engine stub (throws `AvmConfigurationException` until the in-process `PSRule.Rules.Azure` invocation lands) + tests; verb registry route `avm check policy`
- [x] `Invoke-AvmCheckConvention` public verb + `Invoke-AvmBicepCheckConvention` engine stub (throws `AvmConfigurationException` until the `module.tests.ps1` compliance port lands) + tests; verb registry route `avm check convention`
- [x] `Invoke-AvmPreCommit` composition (`format` → `lint` → `test` → `docs`, fail-soft by default, `-StopOnFail` for early exit)
- [x] `Invoke-AvmPrCheck` composition (`format` → `transform` → `lint` → `check policy` → `check convention` → `test` → `docs`; verb registry route `avm pr-check`; AvmConfigurationException from stubbed engines is reported as `skipped` so the chain keeps running and overall status is not failed by a skip; `-StopOnFail` opts into fail-fast)
- [x] `bicep` entry in `tools.lock.psd1` (0.30.3, six-platform SHA256, `platformAliases` for `bicep-{platform}` asset naming)

### Heavy verbs from plan §4 (not started)

- [ ] `avm new` — scaffold new resource/pattern/utility module (replaces `Set-ModuleFileAndFolderSetup.ps1`)
- [ ] `avm transform` — regenerate README + test scaffolding (the `Set-AVMModule.ps1` replacement)
- [ ] `avm docs` Bicep engine — **the ARM-JSON walker** that replaces `Set-ModuleReadMe.ps1` (currently stubbed with `AvmConfigurationException`)
- [ ] `avm check policy` — PSRule.Rules.Azure in-process invocation
- [ ] `avm check convention` — port (or wrap) the ~500-line compliance Pester suite (`module.tests.ps1`)
- [ ] `avm test integration` — ARM what-if via `Test-TemplateDeployment.ps1` (today Phase 0 `avm test` is the cheap build-validate pass only)
- [ ] `avm test e2e` — actual deployment via `New-TemplateDeployment.ps1`
- [ ] `avm pr-check` composition (every check that runs in CI today)
- [ ] `avm publish` — `bicep publish` to Public Bicep Registry, gated by `Test-AvmModuleLayout`-style casing guards
- [ ] `avm release` — version.json + changelog + open PR
- [ ] `avm index update` — wrap `Invoke-AvmJsonModuleIndexGeneration.ps1`
- [ ] Demo fork of `Azure/bicep-registry-modules` exercising the new verbs end-to-end on a handful of modules without changing existing CI
- [ ] `docs/migration-bicep.md` — "instead of running `pwsh -File utilities/tools/Set-AVMModule.ps1 …` run `avm transform …`"

---

## Phase 2 — Terraform facade

### Already in place (scaffolding)

- [x] `Format-AvmTerraformModule` engine (`terraform fmt -recursive`, parses `-list` output into `Changed`) + tests
- [x] `Invoke-AvmTerraformLint` engine (`tflint --recursive --format=json`, exit 0/2 = OK, anything else throws) + tests
- [x] `Invoke-AvmTerraformTest` engine (`terraform validate -no-color -json` with auto `terraform init -backend=false`, `-NoInit` opt-out) + tests
- [x] `Invoke-AvmTerraformDocs` engine (`terraform-docs markdown table --output-mode inject`, README hash diff for `Changed`) + tests
- [x] `Invoke-AvmTerraformTransform` engine stub (throws `AvmConfigurationException` until `mapotf transform`/`mapotf clean-backup` and the `mapotf` lock entry land) + tests, reached via `avm transform`
- [x] `Invoke-AvmTerraformCheckPolicy` engine stub (throws `AvmConfigurationException` until the `conftest` invocation against APRL + AVMSEC bundles and the `conftest` lock entry land) + tests, reached via `avm check policy`
- [x] `Invoke-AvmTerraformCheckConvention` engine stub (throws `AvmConfigurationException` until `grept run` against the pinned `grept-policies` bundle and the `grept` lock entry land) + tests, reached via `avm check convention`
- [x] `terraform`, `tflint`, `terraform-docs` entries in `tools.lock.psd1` (six-platform SHA256s; `tflint` declares `windows-arm64` `unsupportedPlatforms`)

### Phase 2 deliverables from plan §7 (not started)

- [ ] `avm format` enhancement — chain `avmfix` after `terraform fmt` (per plan: "format → `terraform fmt` + `avmfix`")
- [ ] `avm check policy` — `conftest test` against APRL + AVMSEC bundles
- [ ] `avm check convention` — `grept run`
- [ ] `avm transform` — `mapotf transform --mptf-dir … --tf-dir …` then `mapotf clean-backup`
- [ ] Pinned-asset feature: download governance assets (`mapotf-configs/`, `grept-policies/`, `tflint-configs/`, Conftest bundles) at a configurable ref via `avm.config.json`
- [ ] Add `avmfix`, `mapotf`, `grept`, `conftest` to `tools.lock.psd1` with verified six-platform SHA256s
- [ ] `avm test integration` / `avm test e2e` for Terraform (Phase 0 `avm test` is `terraform validate` only)
- [ ] `avm pre-commit` Terraform path composing `format` + `transform` + `convention` + `validate` + `docs` per plan §4
- [ ] `avm pr-check` Terraform composition
- [ ] Demo on `Azure/terraform-azurerm-avm-res-keyvault-vault` (or mock module): bare workstation, no container, no repo-local `./avm` script
- [ ] `docs/migration-terraform.md`

---

## Phase 3 — Replace `porch` orchestration

- [ ] Invoke-Build task scripts for every `porch-configs/*.porch.yaml` pipeline (`pre-commit`, `pr-check`, `test-examples`, `terraform-test`, `global-setup`, `global-teardown`)
- [ ] Per-example pre/post-hook engine reimplemented in PowerShell (`pre.sh`/`pre.ps1`/`post.sh`/`post.ps1`, `.env` sourcing)
- [ ] TUI / progress replacement (Spectre.Console if Hybrid kicks in; pure-PS `Write-Progress` until then)
- [ ] `--use-porch` legacy escape hatch retained for one release
- [ ] Exit criterion: a Terraform module repo can drop its `Makefile` + `porch-configs` dependency and rely solely on the CLI

---

## Phase 4 — Selective `mapotf` / `grept` port

- [ ] Rule registry that loads `*.avmrule.psd1` / `*.avmrule.cs` from a folder
- [ ] Native PowerShell port: `required_provider_versions.mptf.hcl` (HCL `required_providers` edit helper)
- [ ] Native port: `outputs_tf.grept.hcl` / `variables_tf.grept.hcl` (file rename helpers)
- [ ] Native port: `git_ignore.grept.hcl` (idempotent `.gitignore` enforcement)
- [ ] Native port: `ensure_file_existence.grept.hcl`, `ensure_dir_existence.grept.hcl`, `deprecated_files.grept.hcl`
- [ ] Keep complex transforms on the Go binaries via the same registry (`main_telemetry_tf.mptf.hcl`, `avm_headers_for_azapi.mptf.hcl`)
- [ ] Exit criterion: at least half of today's `mapotf` + `grept` rule files run natively

---

## Phase 5 — Governance script consolidation

- [ ] `avm governance issue sync` (wraps `Set-AvmGitHubIssueForWorkflow` + `Set-AvmGitHubIssueOwnerConfig`)
- [ ] `avm governance pr label` (wraps `Set-AvmGitHubPrLabels`)
- [ ] `avm governance workflow rerun` (wraps `Invoke-WorkflowsFailedJobsReRun`)
- [ ] `avm governance workflow trigger` (wraps `Invoke-WorkflowsForBranch`)
- [ ] `avm governance workflow toggle` (wraps `Switch-WorkflowState`)
- [ ] `avm governance reaper run` (port of `tf-repo-mgmt/reaper/ReaperScript.ps1`)
- [ ] Unified `GitHubClient` helper replacing per-script REST calls
- [ ] `Get-AvmCsv` cmdlet wrapping the canonical AVM CSV
- [ ] Exit criterion: every `platform.*.yml` workflow expressible as `pwsh -c "avm governance …"`

---

## Phase 6 — Upstream promotion

- [ ] PR to `Azure/bicep-registry-modules`: switch composite actions + workflows to `avm` verbs, delete legacy `utilities/tools/*.ps1` entry-point scripts
- [ ] PR to `Azure/avm-terraform-governance`: delete `./avm`, `./avm.ps1`, `Makefile`; move `porch-configs/`, `mapotf-configs/`, `grept-policies/` to `legacy/`
- [ ] Templated PR to every Terraform module repo: delete `./avm`, `./avm.ps1`, `Makefile`; README pointer to `Install-Module Avm`
- [ ] `docs/legacy-tooling.md` migration doc in each upstream repo (one row per removed script with its `avm` verb equivalent)
- [ ] Container retirement notice: `mcr.microsoft.com/azterraform:avm-*` marked deprecated in `Azure/avm-terraform-governance` README
- [ ] Exit criterion: both upstream repos build and pass CI on standard runners with no container step and no repo-local entry-point scripts

---

## Cross-phase / spec backlog

Items from the spec ([`avm-implementation-spec.md`](avm-implementation-spec.md)) and plan ([`avm-consolidation-plan.md`](avm-consolidation-plan.md)) that don't sit in a single phase:

- [ ] Console encoding opt-out documented (spec §23 OQ 2 — already implemented via `AVM_NO_CONSOLE_CONFIG`, just needs a CONTRIBUTING / README mention)
- [ ] Decision + design note for `dotnet tool` packaging (spec §23 OQ 5)
- [ ] Decision + design note for SecretManagement vs file-based credential storage (spec §23 OQ 1)
- [ ] Telemetry design note (spec §21 + plan §12 OQ 5): payload, endpoint, opt-out
- [ ] Long-path support story on Windows (spec §23 OQ 6)
- [ ] `pre-commit` Pester suite (spec §19): manifest layout + encoding check + PSScriptAnalyzer + Pester Unit, wired through `./build.ps1 pre-commit`
- [ ] PSScriptAnalyzer custom rule `AvmAvoidStringThrow` (spec §14)
