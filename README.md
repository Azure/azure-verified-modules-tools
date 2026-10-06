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

> **Heads-up.** The Terraform authoring chain is wired and usable today; the Bicep facade is still in active development. Find active slice records through [docs/progress.md](docs/progress.md). To run the latest in-development build, import it from a clone — see [CONTRIBUTING.md](CONTRIBUTING.md).

For Bicep modules with `main.bicep`, `avm pre-commit` writes the compiled
`main.json`; `avm pr-check` reports missing or stale output without rewriting
it. Metadata-only proposed modules do not require compiled JSON.
The Bicep `avm docs` migration uses a tracked, repository-selected Scriban
template and adjacent Notes sidecars. It remains experimental until all
registry READMEs pass an independent raw-byte comparison, apart from eight
historically missing JSON-example comment lines in the checked-in Key Vault
README. The existing registry generator and CI stay in place.

## Managed prerequisites

`avm pre-commit` and `avm pr-check` resolve their applicable tools before the
first step, including Pester for metadata validation. Standalone commands use
the same resolver. Missing binary and PowerShell packages are downloaded into
the AVM cache at their configured versions, with checksum verification; no
user or system PowerShell module installation is needed. `AVM_OFFLINE=1` and
`AVM_NO_AUTO_INSTALL=1` remain effective. Use `avm tool list` to inspect
availability or `avm tool install Pester` to populate a prerequisite explicitly.

An optional repository-root `.avm/tool-version-overrides.json` selects versions
of known tools without replacing their download definitions:

```json
{
  "terraform": "1.16.5",
  "Pester": "5.7.1"
}
```

Names are case-sensitive. For Bicep monorepos, only the recognized repository
root file applies to every module; nested module files are ignored. Selected
overrides emit a warning with the file and packaged/selected versions, even
when the versions match.

**Overrides disable pinned checksum verification for the named tools.** They
use a separate unverified cache and never replace verified default entries.
Untouched tools and dependencies remain pinned. Review this file as an
executable-toolchain change before running commands with privileged access.
After loading an overridden PowerShell module, use a fresh PowerShell session
when returning to the default version.

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

- [docs/progress.md](docs/progress.md) — progress protocol and active-slice discovery; read this first.
- [CONTRIBUTING.md](CONTRIBUTING.md) — run the module from source, plus the build / test / lint dev loop.
- [docs/migration-terraform.md](docs/migration-terraform.md) — migrating off `make` / `./avm` / the `azterraform` container / `porch`.
- [docs/avm-consolidation-plan.md](docs/avm-consolidation-plan.md) and [docs/avm-implementation-spec.md](docs/avm-implementation-spec.md) — the phased plan and the engineering spec.

## License

[MIT](LICENSE).
