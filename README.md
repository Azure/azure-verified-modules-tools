# Azure Verified Modules — Tools

Source for the **`Avm.Authoring`** PowerShell module: a single, cross-platform PowerShell 7 tool that consolidates the scripts and CI helpers used by authors of [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) (Bicep and Terraform).

One `avm` CLI, two ecosystems, no Docker / `make` / `porch` required for the wired verbs.

The build-out is staged in phases per [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md). The engineering rulebook for the implementation lives in [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md). The live status checklist (single source of truth — read first when contributing) is [docs/progress.md](docs/progress.md). Contributors start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Status

| Phase | Theme                          | Status                                                                                                                                                              |
| :---: | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|   0   | Skeleton + parity CI           | **Complete** — `layout` / `lint` / `test` / `coverage` / `integration` / `build` / `smoke` tasks all green; release pipeline ready; 78.83% line coverage vs 70% floor |
|   1   | Bicep facade                   | **Partial** — `format` / `lint` / `test` engines wired; `docs` is a stub (new dedicated CLI command being designed); heavier verbs (`new`, `transform`, policy) not started |
|   2   | Terraform facade               | **Active — `pre-commit` and `pr-check` end-to-end green at Unit + Integration tier**. `format` / `lint` / `test` / `docs` / `check policy` engines wired. `transform`, `check convention`, and `format`→`avmfix` chain blocked on the [Phase 2 §2 supply-chain decision](docs/progress.md#phase-2--terraform-facade) |
|   3   | Replace `porch` orchestration  | Not started                                                                                                                                                          |
|   4   | Selective `mapotf` / `grept` port | Not started                                                                                                                                                       |
|   5   | Governance script consolidation | Not started                                                                                                                                                         |
|   6   | Upstream promotion             | Not started                                                                                                                                                          |

The module is published to PSGallery as `Avm.Authoring`; the current published version is a `0.0.1` placeholder while the active development version on this branch is `0.1.0`. See [docs/progress.md](docs/progress.md) for the slice-level checklist.

## Quick start

From a clone of this repo:

```pwsh
Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force

avm                 # show every available verb
avm version         # CLI / runtime info
avm doctor          # diagnose the local environment
avm context         # resolved module context (paths, ecosystem, lock file)
avm tool list       # show managed tool entries (terraform, tflint, etc.)
```

Per-ecosystem engines (Bicep and Terraform both accept `-Ecosystem`; if omitted, the dispatcher auto-detects from `*.tf`/`*.bicep` files in the path):

```pwsh
avm format          # bicep / terraform fmt
avm lint            # PSScriptAnalyzer (build-time) / tflint / bicep build (lint)
avm test            # bicep build / terraform validate (cheap pass)
avm docs            # terraform-docs README inject (bicep docs is currently stubbed)
avm check policy    # conftest against pinned APRL + AVMSEC OPA bundles (terraform only today)
```

Compositions that contributors actually run:

```pwsh
avm pre-commit -Ecosystem terraform   # format -> lint -> test -> docs
avm pr-check   -Ecosystem terraform   # format -> transform -> lint -> check policy -> check convention -> test -> docs
```

Steps whose engine isn't wired yet (`transform`, `check convention` on Terraform; `docs` on Bicep) report as `skipped` rather than failing — composition stays green.

## Try it on a real Terraform module

```pwsh
git clone https://github.com/Azure/terraform-azurerm-avm-res-keyvault-vault
cd terraform-azurerm-avm-res-keyvault-vault
Import-Module <path-to>/azure-verified-modules-tools/src/Avm.Authoring/Avm.Authoring.psd1 -Force

avm pre-commit -Ecosystem terraform -Path .
```

The first run downloads `terraform`, `tflint`, and `terraform-docs` into the managed cache (`$env:AVM_HOME/cache/tools/...`); subsequent runs reuse the cached binaries. Set `$env:AVM_OFFLINE=1` to refuse network downloads, or `$env:AVM_MIRROR=https://your-mirror/` to route the same URLs through a corporate mirror.

## Migrating off the legacy stack

If you currently run `make pre-commit`, `make pr-check`, `./avm`, the `mcr.microsoft.com/azterraform:avm-*` container, or anything plumbed through `Azure/avm-terraform-governance`'s runtime `Makefile` downloader — see **[docs/migration-terraform.md](docs/migration-terraform.md)** for drop-in mapping tables, the pinned-asset config example that replaces the `AVM_*_URL` env-var stack, and the per-engine status matrix showing which legacy steps are wired today.

## Repository layout

```text
build/                  Invoke-Build task graph (./build.ps1 forwards here)
docs/                   Plan + spec + tooling inventory + migration guides + live progress checklist
out/                    Build outputs (staged module, coverage XML); gitignored
scripts/                Operational scripts (publish, release, tools.lock updates)
src/Avm.Authoring/      Module source (Public/, Private/, Resources/)
tests/Pester/           Unit / Integration / Smoke test trees
tests/fixtures/         Fake Bicep and Terraform modules + stub binaries used by tests
```

## Development loop

```pwsh
./build.ps1 layout       # casing + manifest guards (fast)
./build.ps1 lint         # PSScriptAnalyzer + custom AvmAvoidStringThrow rule
./build.ps1 test         # Pester Unit (excludes Smoke + Integration)
./build.ps1 pre-commit   # layout + lint + test (the recommended local gate)
./build.ps1 coverage     # Pester with coverage (JaCoCo XML under out/coverage/)
```

`./build.ps1 pre-commit` is the gate enforced by `AGENTS.md` before any code commit. Doc-only commits skip the gate.

## License

[MIT](LICENSE).
