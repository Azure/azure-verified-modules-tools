# Changelog

All notable changes to `Avm.Authoring` will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

The release workflow (`.github/workflows/release.yml`) extracts the section
matching the git tag (e.g. tag `v0.1.0` → section `## [0.1.0]`) and publishes
it as the GitHub Release body. Tagged releases without a matching section
fail the workflow before any PSGallery publish runs.

## [Unreleased]

Tracking work after `0.1.0`. Move bullets into a dated version section when
cutting a release.

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

[Unreleased]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/Azure/azure-verified-modules-tools/releases/tag/v0.0.1
