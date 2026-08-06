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

> **Heads-up.** The Terraform authoring chain is wired and usable today; the Bicep facade is still in active development. Track the slice-level status in [docs/progress.md](docs/progress.md). To run the latest in-development build, import it from a clone — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Verify the signature

Every `.ps1`, `.psm1` and `.psd1` in a released build is Authenticode-signed by Microsoft. To check what you installed:

```pwsh
Get-ChildItem (Get-Module Avm.Authoring -ListAvailable).ModuleBase -Recurse -Include *.ps1, *.psm1, *.psd1 |
    Get-AuthenticodeSignature |
    Group-Object Status, { $_.SignerCertificate.Subject }
```

Expect a single group with status `Valid` and a `Microsoft Corporation` subject. Anything reporting `NotSigned`, `HashMismatch` or `UnknownError` means the file has been modified or came from somewhere other than the gallery.

The release `.zip` attached to each [GitHub Release](https://github.com/Azure/azure-verified-modules-tools/releases) ships alongside a `SHA256SUMS` file:

```pwsh
(Get-FileHash ./Avm.Authoring-0.2.0.zip -Algorithm SHA256).Hash.ToLowerInvariant()
Get-Content ./SHA256SUMS
```

## Learn more

- [docs/progress.md](docs/progress.md) — live status checklist and single source of truth; read this first.
- [CONTRIBUTING.md](CONTRIBUTING.md) — run the module from source, plus the build / test / lint dev loop.
- [docs/migration-terraform.md](docs/migration-terraform.md) — migrating off `make` / `./avm` / the `azterraform` container / `porch`.
- [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md) and [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md) — the phased plan and the engineering spec.

## License

[MIT](LICENSE).
