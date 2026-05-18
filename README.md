# Azure Verified Modules — Tools

Source for the **`Avm.Authoring`** PowerShell module: a single, cross-platform PowerShell 7 tool that consolidates the scripts and CI helpers used by authors of [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) (Bicep and Terraform).

The build-out is staged in phases per [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md). The engineering rulebook for the implementation lives in [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md). Contributors start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Status

| Component                        | Phase | Status                                                                                                      |
| -------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------- |
| `Avm.Authoring` placeholder      | —     | [Published to PSGallery (`0.0.1`)](https://www.powershellgallery.com/packages/Avm.Authoring)                |
| Phase 0 skeleton                 | 0     | In progress (this repo)                                                                                     |
| Bicep facade (`avm pre-commit`, `avm test bicep`)   | 1 | Not started                                                                                       |
| Terraform facade (`avm test terraform`, `avm release-please`) | 2 | Not started                                                                          |

## Quick start

From a clone of this repo:

```pwsh
Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1 -Force

avm                 # show available verbs
avm version         # CLI / runtime info
avm doctor          # diagnose the local environment
```

The full dev loop (`./build.ps1 pre-commit`, running individual Pester tests, installing the module to user scope, publishing) is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository layout

```text
build/                  Invoke-Build task graph (./build.ps1 forwards here)
docs/                   Plan + spec + historical inventory
scripts/                Operational scripts (publish, release helpers)
src/Avm.Authoring/      Module source (Public/, Private/, Resources/)
tests/Pester/           Unit / Integration / Smoke test trees
tests/fixtures/         Fake Bicep and Terraform modules used by tests
```

## License

[MIT](LICENSE).
