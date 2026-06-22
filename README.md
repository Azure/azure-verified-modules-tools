# Azure Verified Modules — Tools

Source for the **`Avm.Authoring`** PowerShell module: a single, cross-platform PowerShell 7 tool that consolidates the scripts and CI helpers used by authors of [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) (Bicep and Terraform).

One `avm` CLI, two ecosystems, no Docker / `make` / `porch` required for the wired verbs.

## Install

The module is published to the PowerShell Gallery as [`Avm.Authoring`](https://www.powershellgallery.com/packages/Avm.Authoring). PowerShell 7.4+ is required.

```pwsh
# Modern — Microsoft.PowerShell.PSResourceGet (ships with PowerShell 7.4+)
Install-PSResource Avm.Authoring

# Classic — PowerShellGet v2
Install-Module Avm.Authoring -Scope CurrentUser
```

Then import it and confirm it loaded:

```pwsh
Import-Module Avm.Authoring
avm version
```

> **Heads-up on versions.** The package currently published to the Gallery is a `0.0.1` placeholder that reserves the name. The full Bicep + Terraform `avm` CLI (manifest version `0.1.0`) is under active development in this repo and has **not** been published yet, so installing from the Gallery today gives you the placeholder only. Track the slice-level status in [docs/progress.md](docs/progress.md). To run the in-development CLI now, import it from a clone — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Learn more

- [docs/progress.md](docs/progress.md) — live status checklist and single source of truth; read this first.
- [CONTRIBUTING.md](CONTRIBUTING.md) — run the module from source, plus the build / test / lint dev loop.
- [docs/migration-terraform.md](docs/migration-terraform.md) — migrating off `make` / `./avm` / the `azterraform` container / `porch`.
- [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md) and [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md) — the phased plan and the engineering spec.

## License

[MIT](LICENSE).
