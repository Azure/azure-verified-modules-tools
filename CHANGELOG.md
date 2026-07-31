# Changelog

All notable changes to `Avm.Authoring` will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

The release workflow (`.github/workflows/release.yml`) takes the git tag as the
single source of truth for the version: it stamps the tag version into the
staged manifest at build time, so `ModuleVersion` in the repo never has to be
bumped before tagging. If a section matching the tag exists (e.g. tag `v0.1.0`
→ section `## [0.1.0]`) it seeds the GitHub Release body and the gallery
release notes; otherwise the release falls back to GitHub's auto-generated
notes. A missing section no longer fails the release.

## [Unreleased]

Bullets below describe work that shipped untagged in `0.1.3` and `0.1.4`, which
were both cut without CHANGELOG sections. Move new bullets into a dated version
section when cutting a release.

### Added

- `avm check policy` for Terraform: real `conftest` integration that runs the
  pinned APRL + AVMSEC Rego bundles against the `terraform plan` JSON for each
  example, with per-example `exceptions/*.rego` discovery. Bundles are
  materialised on demand from the `pinned-assets.psd1` registry, sha256-verified
  on first download, cached under `AVM_HOME`, and re-used offline.
- `pinned-assets.psd1` configuration reader (`Get-AvmPinnedAsset`) and cache
  materialiser (`Resolve-AvmPinnedAsset`) that honour `AVM_OFFLINE` and
  `AVM_MIRROR` and reuse the existing `Get-AvmFolder` cache layout.
- `conftest` (0.68.2) pinned in `tools.lock.psd1` for all six OS/arch
  platforms; resolvable through the standard managed-tool resolver.
- `AvmAvoidStringThrow` custom PSScriptAnalyzer rule that flags
  `throw "string"` in `src/Avm.Authoring/**` and steers code toward the typed
  `AvmException` hierarchy. Wired into `./build.ps1 lint` (and therefore the
  `pre-commit` / `ci` chains).
- `AVM_NO_CONSOLE_CONFIG` env-var opt-out for the host PSReadLine prediction
  shim, for CI and script callers that can't tolerate console-config probing.

### Changed

- The release workflow no longer requires `ModuleVersion` in the repo manifest
  to match the tag being released, and no longer fails when the tag has no
  CHANGELOG section. `./build.ps1 build -ReleaseVersion X.Y.Z` stamps the
  version (and the matching CHANGELOG section, when present) into the staged
  manifest under `out/`; the in-repo manifest is never rewritten.
- `Invoke-AvmBicepDocs` reverted to a clean `AvmConfigurationException` stub
  on 2026-05-26 in a deliberate pivot to prioritise Terraform-first delivery.
  The intervening ARM-JSON walker spike (slices 4a–4f: outputs, resource-types,
  Parameters summary, per-parameter detail blocks, inline-object recursion,
  `$ref`/UDT resolution, array `items` traversal, discriminated-union
  dispatch, and the secure-type contract) was implemented end-to-end and then
  removed wholesale. A future design will shell out to a dedicated Bicep docs
  CLI when one is selected.
- `docs/avm-consolidation-plan.md` verb-table entries for `avm docs` (Bicep),
  `avm pre-commit`, and `avm pr-check` rewritten to match the engines as
  wired today (`format → lint → test → docs` for `pre-commit`;
  `format → transform → lint → check policy → check convention → test → docs`
  for `pr-check`, with `skipped` semantics for stubbed engines).

### Tests

- Terraform engine stub harness under `tests/Pester/Integration/Terraform/`
  that exercises `Invoke-AvmPreCommit` and `Invoke-AvmPrCheck` end-to-end
  against stub `terraform` / `tflint` / `terraform-docs` / `conftest`
  binaries injected onto the PATH.
- End-to-end coverage of `Invoke-AvmCheckPolicy` (Terraform) via a stub
  `conftest` binary that simulates pass, deny, and exception-suppression
  scenarios.
- Public-verb smoke test for the `Invoke-AvmPreCommit` composition (covers
  Terraform alongside the existing Bicep coverage).
- PSScriptAnalyzer rule-test helper made array-safe to remove a CI flake.

### Docs

- Root `README.md` refreshed to reflect the actual repo state after the
  2026-05-26 Terraform-first pivot.
- New `docs/terraform-migration.md` migration guide.
- `docs/progress.md` audit of Terraform tool binary availability — 3 of 4
  candidates (`mapotf`, `avmfix`, `grept`) ship no GitHub releases, blocking
  `avm transform` / `avm check convention` / the `avmfix`-format-chain on an
  A/B/C supply-chain decision.
- Confirmed the spec §19 pre-commit Pester suite is ghost-complete (no
  additional test work required to satisfy that line item).
- `AVM_NO_CONSOLE_CONFIG` documented in the host shim README/inline help.

## [0.1.7] - 2026-07-31

Second remediation round from end-to-end testing released `0.1.6` against the
canary repo `Azure/terraform-azurerm-avm-ptn-example-repo` (F23–F31).

### Added

- `avm test e2e --example <name>` targets a single example. It accepts either
  the folder leaf (`example-a`) or a repo-relative path (`examples/example-a`)
  and may be repeated. Omitting it keeps the existing behaviour of running every
  runnable example sequentially. A name that does not exist, or that carries a
  `.e2eignore` marker, is a hard error listing the valid names rather than a
  silent pass, so a typo in a CI matrix cannot skip a real test. (F26)
- `avm test e2e --list` emits a compact JSON array of runnable example names and
  nothing else, so a workflow can build a matrix with `fromJson()` and no
  post-processing. A module with no runnable examples emits `[]`. (F27)
- The Terraform reusable workflow fans end-to-end tests out across a per-example
  matrix with `fail-fast: false`, restoring the governance round-robin
  subscription fan-out so parallel legs do not collide on quota. The matrix is
  skipped cleanly when a module has no runnable examples.
- Every step and sub-step now carries `StartTime`, `EndTime` and a duration, both
  on the result objects and in the rendered output. (F29)
- `RUNNER_DEBUG=1` (set when a workflow is re-run with debug logging) turns
  verbose on, and verbose now cascades from the entry point to engines,
  sub-cmdlets and `Invoke-AvmProcess`. `AVM_VERBOSE=1` does the same outside
  GitHub Actions. (F30)

### Changed

- All module output routes through a single writer with levels, which is GitHub
  Actions aware (`::group::`, `::error::`, `::warning::`, `::debug::`) instead of
  mixing `Write-Host`, `Write-Information` and `Write-Verbose`. (F31)
- Subprocess output is quiet by default and replayed in full at the point of
  failure. Verbose or debug streams it live; GitHub Actions wraps it in a
  collapsed `::group::` so the log is present but not noisy. Long-running
  sub-steps emit a periodic elapsed-time heartbeat so a slow deploy is
  distinguishable from a hang. (F28)
- `avm` renders one summary per invocation instead of one per emitted result
  object, and labels per-item rows with the item's own identity, so
  `avm tool list` no longer reads as six conflicting statuses for one command.
  (F25)
- `avm` no longer writes result objects to the success stream by default; pass
  `--passthru` to get them back for scripting. (F23)

### Fixed

- A failing `avm` command reports a clean one-line failure summary and exits
  non-zero instead of surfacing a raw `OperationStopped` stack trace pointing at
  module source. The remainder of a calling script no longer stops running, so
  cleanup lines after an `avm` call execute as written. (F24)
- A gauntlet step that fails or errors now narrates its error message at the
  point of failure, so callers that invoke `Invoke-AvmPrCheck` or
  `Invoke-AvmPreCommit` directly (bypassing the dispatcher's renderer) get a
  diagnosis instead of a bare status.

## [0.1.6] - 2026-07-31

### Added

- Every `avm` status result now renders a concise command status, chain step
  status/error/duration, and issue detail on the Information stream. GitHub
  Actions runs append the same diagnostics to `GITHUB_STEP_SUMMARY`. (F20, F21)
- `Invoke-AvmProcess -StreamOutput` emits child stdout and stderr while retaining
  both captured values. Terraform init, integration tests, and e2e lifecycle
  operations and hooks enable it by default. (F21)

### Fixed

- `avm transform` removes every PATH entry containing another platform-specific
  terraform executable before exposing the resolved pinned terraform to mapotf.
  The override is scoped to the mapotf child process. (F19)
- `AvmCommandException` includes the first failing step or issue diagnostic
  instead of reporting only the aggregate status. (F20)
- The Terraform reusable workflow no longer masks the non-secret subscription
  ID before publishing it as a job output, so downstream Azure test jobs receive
  `ARM_SUBSCRIPTION_ID`. (F22)

## [0.1.5] - 2026-07-30

Remediation of the 18 defects (F01–F18) found while end-to-end testing `0.1.4`
against the canary repo `Azure/terraform-azurerm-avm-ptn-example-repo`.

### Added

- Pinned tools now **install themselves on demand**. Any gauntlet verb that
  needs `terraform`, `tflint`, `terraform-docs`, `conftest` or `mapotf` acquires
  it transparently through the existing pin manifest, SHA-verified cache and
  cross-process lock, so a clean machine or CI runner needs no `avm tool
  install` step. Set `AVM_NO_AUTO_INSTALL=1` to restore the previous hard
  failure in locked-down or air-gapped environments. (F06)
- Managed files can now **merge line sets into an existing file** instead of
  replacing it, so a consumer's own `.gitignore` additions survive a sync. A
  `.avm-managed-lines.json` in each managed-file group folder maps a
  forward-slash relative path to `{ required: [...], removed: [...] }` — lines to
  ensure present and lines to retire. Specs stack across overlays in the same
  root-then-ascending order as managed files themselves, with last-writer-wins
  per line, so canary and other groups can layer their own. A missing target
  file is created like any other managed file.
- `Resources/tflint/` ships the three governance TFLint rulesets
  (`avm.tflint.hcl`, `avm.tflint_module.hcl`, `avm.tflint_example.hcl`), and
  `Resources/mapotf/pre-commit/` ships the nine mapotf transform configs, so
  neither is resolved from outside the installed module. (F16, F03)
- `Resources/avm.pins.jsonc` is a single commented manifest holding **every**
  version pin — managed tools, the `Azure/policy-library-avm` bundle and the
  TFLint plugins — replacing the scattered `tools.lock.psd1` /
  `pinned-assets.psd1` pair. `scripts/Update-AvmPins.ps1` refreshes it in place
  while preserving comments.
- Release runs now verify the published version is actually resolvable via
  `Find-PSResource` and emit a warning annotation if gallery indexing has not
  caught up, instead of leaving consumers with a bare 404. (F14)

### Fixed

- **Repository identity is resolved from the git origin**, not the directory
  leaf name. Resolution order is explicit `-RepoId`, then
  `AVM_MANAGED_FILES_REPO_ID`, then the origin remote (HTTPS or SCP-style SSH,
  with or without `.git`, `terraform-azurerm-` / `terraform-azapi-` prefix
  stripped), then the folder leaf, then an interactive prompt, then a hard
  failure. A candidate is only accepted when it matches a governance
  `repositoryGroups` entry, and zero matching overlays is now an error rather
  than a silently successful root-only sync. This stops a worktree, fork or
  renamed clone from reverting a repo to the legacy container/make toolchain.
  (F11, F01)
- `avm` **exits non-zero** when a verb reports `Status='fail'` or
  `Status='error'`, so git hooks and CI steps can no longer pass silently. The
  reusable workflow's hand-rolled `$result.Status` wrappers have been removed
  accordingly. (F02, F18)
- `avm lint` applies the AVM TFLint rulesets. The single `--recursive`
  default-config invocation is replaced by deterministic per-scope runs — repo
  root, each `modules/*` and each `examples/*` — each initialised and linted
  with its matching config via an absolute `--config` path. (F16)
- Lint **fails on warnings** by default, which is the severity most built-in
  TFLint rules emit. Override with
  `-MinimumFailureSeverity error|warning|notice`. (F17)
- `avm transform` resolves its mapotf configs from `AVM_MPTF_CONFIG_DIR`, then
  the consumer repo's `config/mapotf/pre-commit`, then the packaged bundle. The
  previous lookup walked two levels above the installed module root and landed
  inside `PSModulePath`. (F04, F03)
- `avm check policy` works on a clean checkout. `.avm/config.json` is gone
  entirely — the module now carries immutable APRL/AVMSEC descriptors in the pin
  manifest — so the repo no longer has to satisfy a rule requiring a file that
  was simultaneously gitignored and never generated. (F07)
- `terraform.tf` is required at the Terraform repository root and in nested
  `modules/*`, but **not** under `examples/*`, so a clean canonical example repo
  passes `avm check convention`. Rule `AppliesTo` is now a normalised scope
  array rather than a single string, because the old model could not express
  this. (F08)
- Sync **never touches the git index**. Executable-mode repair mutates the
  working tree only, so a subsequent `git commit` cannot silently pick up
  unrelated staged changes. (F13)
- `avm tool list` and the engines agree on what is resolvable; PATH fallback is
  only reported where it is actually accepted. (F05)
- Engine results share a common contract — `Status`, `FilesProcessed`,
  `Changed`, `Issues` — so callers can uniformly test `$result.Status`.
  `avm format` reports a real `Status` and a real file count instead of the
  `-1` sentinel. (F15)
- `avm --help` and `avm -h` print the same help as a bare `avm`, and the
  `pre-commit` summary describes the steps it actually runs. (F09)

### Changed

- **Breaking**: the canonical rule object's `AppliesTo` is now `[string[]]`.
  `'all'` remains valid authored shorthand but is expanded at construction time;
  combining `'all'` with another scope is rejected as ambiguous.
- **Breaking**: `tools.lock.psd1` and `pinned-assets.psd1` are replaced by
  `Resources/avm.pins.jsonc`; the `*ToolsLock*` function family is replaced by
  `Read-AvmPins` / `Test-AvmPins` / `Install-AvmToolFromPins`.
- **Breaking**: `.avm/config.json` and the `avm.smoke.avm-config-exists` rule
  are removed. `.avm/` is never created by any verb and is no longer required in
  a consumer `.gitignore`; all persistent state lives under `AVM_HOME`.
- The `psgallery` release environment is documented as deliberately gate-free.
  A required reviewer there parks the run in `status=waiting` while the GitHub
  Release already looks published and the gallery 404s — the exact failure v0.1.4
  hit for ~53 minutes. (F14)

### Tests

- Regression coverage for repo-id resolution (HTTPS, HTTPS with `.git`, SSH,
  no origin, renamed worktree, folder fallback, non-interactive hard failure),
  multi-overlay stacking by ascending `managedFilesOrder` (F12), git-index
  preservation across a sync (F13), tool auto-install (cold, warm, opt-out,
  installer failure) and per-scope TFLint invocation.
- A shell-out test that invokes a failing verb through `pwsh -File` and
  `pwsh -Command` and asserts a non-zero **process** exit code, mirroring a
  `run:` step with `shell: pwsh`. (F02)

## [0.1.2] - 2026-07-30



Terraform test tiers and managed-file synchronisation.

### Added

- Tiered Terraform testing: `avm test-unit` (`Invoke-AvmTestUnit`),
  `avm test-integration` (`Invoke-AvmTestIntegration`) and `avm test-e2e`
  (`Invoke-AvmTestE2e`), backed by `Invoke-AvmTerraformTestSuite` and
  `Invoke-AvmTerraformTestE2e`.
- `avm sync` (`Invoke-AvmSync`) with the `Sync-AvmManagedFile` engine, to pull
  AVM-managed files into a module repository.
- `ConvertFrom-AvmDotEnv` for reading `.env` files used by the e2e tier.
- `.github/workflows/terraform-module.yml`: a reusable workflow that AVM
  Terraform module repositories can call for the full check + test chain.

### Changed

- `Invoke-AvmPreCommit` and `Invoke-AvmPrCheck` updated to compose the new
  test tiers.

## [0.1.1] - 2026-06-23

Release-pipeline and packaging fixes.

### Changed

- Release workflow made idempotent and re-runnable: it now creates the GitHub
  Release only when the tag has none, and otherwise re-uploads artefacts with
  `--clobber` instead of failing with "a release with the same tag name
  already exists".
- PowerShell Gallery description rewritten to describe the shipped Terraform
  chain and the managed-tool resolver rather than the Phase 0 roadmap.
- Workflow, job and step display names polished for readability.

### Added

- `-SkipIfAlreadyPublished` handling in `scripts/Publish-AvmAuthoring.ps1` so a
  re-run against an already-published version is a no-op rather than an error.

## [0.1.0] - 2026-05-18

First real release of `Avm.Authoring` — the Phase 0 skeleton from the
[consolidation plan](docs/avm-consolidation-plan.md) and
[implementation spec](docs/avm-implementation-spec.md). Single `avm`
dispatcher, managed-tool resolver, and Bicep / Terraform inner-loop
scaffolding (`format` / `lint` / `test` / `docs`).

### Added

- `avm` dispatcher (`Invoke-Avm` + `avm` alias) with kebab-case flag → PascalCase parameter coercion, bare-call help, and unknown-verb errors.
- `avm version` (`Get-AvmVersion`) and `avm doctor` (`Invoke-AvmDoctor`) with cross-platform writable-folder probes.
- Managed-tool resolver: `Get-AvmTool`, `Install-AvmTool`, `avm tool list|which|install`, backed by `tools.lock.psd1` (bicep 0.30.3, terraform 1.9.5, terraform-docs 0.18.0, tflint 0.53.0 across all six OS/arch platforms).
- `avm doctor --install` to atomically pre-fetch every managed tool with `AVM1012` skip semantics, `-Force` reinstall, and per-tool `Install-AvmToolFromLock`.
- Cross-OS folder layout (`Get-AvmFolder`) covering Config / Cache / Data / State / Tools / Logs / Temp with `AVM_HOME` override, XDG Base Directory on Linux, Windows Known Folders, and Apple Application Support layout on macOS.
- HTTP layer (`Invoke-AvmHttp`) with TLS 1.2/1.3, mandatory SHA256 verification, `AVM_OFFLINE` gate, `file://` fixture support, partial-file cleanup on hash mismatch, and `AVM_MIRROR` host rewriting via the pure `Resolve-AvmMirrorUrl` helper (preserves mirror path prefix; rejects non-https mirrors with `AvmConfigurationException`).
- Subprocess layer (`Invoke-AvmProcess`): argv-array invocation only (no shell), stdout/stderr split, timeout with process termination, `EnvVars` override, optional `IgnoreExitCode`.
- Exception hierarchy (`AvmException` / `AvmConfigurationException` / `AvmToolException` / `AvmProcessException` / `AvmContextException`) with stable error codes (`AVM1001`, `AVM1010`, `AVM1012`, `AVM1014`, `AVM1020`, `AVM1030`).
- Module context discovery (`Get-AvmModuleContext`) for Bicep monorepos, Bicep modules, Terraform module repos, and Terraform module paths, with `.avm/context.psd1` override and `-Ecosystem` filter.
- `.avm/.disable` sentinel — the dispatcher refuses to run when present.
- Bicep inner loop: `Invoke-AvmFormat` (`bicep format`), `Invoke-AvmLint` (`bicep lint --diagnostics-format defaultV2`), `Invoke-AvmTest` (`bicep build --stdout`). `Invoke-AvmDocs` throws a clear `AvmConfigurationException` until the ARM-JSON walker lands.
- Terraform inner loop: `Format-AvmTerraformModule` (`terraform fmt`), `Invoke-AvmTerraformLint` (`tflint`), `Invoke-AvmTerraformTest` (`terraform init && terraform validate`), `Invoke-AvmTerraformDocs` (`terraform-docs`).
- `Invoke-AvmPreCommit` composition (`format` → `lint` → `test` → `docs`, fail-soft by default, `-StopOnFail` for early exit).
- Build + CI: `./build.ps1` entry forwarding to Invoke-Build with `layout` / `lint` / `test` / `coverage` / `build` / `clean` / `pre-commit` / `ci` tasks; cross-platform CI on ubuntu, windows, macos.
- Spec §18 70% line-coverage floor enforced as a hard build gate in the `coverage` task; CI now runs `layout + lint + coverage`.
- Encoding/EOL guard (`tests/Pester/Unit/Module/Encoding.Tests.ps1`): rejects UTF-8 BOMs and CRLF line endings across every text file under `src/` on every `pre-commit` run.
- Layout guard (`Test-AvmModuleLayout`) with on-disk casing checks for the `Avm.Authoring/` folder and `Avm.Authoring.psd1` manifest filename, plus `PowerShellVersion >= 7.4`.
- `scripts/Publish-AvmAuthoring.ps1` (PSGallery publish with hard casing guards and `-WhatIf`) and `scripts/Update-AvmToolsLock.ps1` (refresh managed-tool SHA256s).
- Backward-compatibility shim `Get-AvmAuthoringPlaceholder` retained from `0.0.1`.

### Tests

- 230 Pester unit tests across `tests/Pester/Unit/{Module,Public,Private,Private/Engines}/`; 2 platform-conditional skips on non-host OSes.
- Aggregate line coverage 78.83% (1,013 of 1,285 commands across 30 files) — well above the 70% floor.

## [0.0.1] - 2026-05-12

Initial placeholder release to reserve the `Avm.Authoring` package name on
PowerShell Gallery. Exposed only the `Get-AvmAuthoringPlaceholder` cmdlet
so callers could verify the module loads end-to-end.

[Unreleased]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/Azure/azure-verified-modules-tools/releases/tag/v0.0.1
