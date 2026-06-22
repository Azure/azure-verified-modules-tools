# On-disk Terraform module fixtures

This tree holds full, copy-faithful AVM Terraform module shells used as
integration-test substrate for `avm pre-commit -Ecosystem terraform`,
`avm pr-check -Ecosystem terraform`, and the individual engine cmdlets
(`Invoke-AvmFormat`, `Invoke-AvmLint`, `Invoke-AvmTest`, `Invoke-AvmDocs`,
`Invoke-AvmCheckPolicy`).

The existing TestDrive-built fixture inside
`tests/Pester/Integration/Invoke-AvmPreCommit.Terraform.Integration.Tests.ps1`
is hand-curated to exercise the engine argv contracts against the stub
launchers under `tests/fixtures/bin/`. The fixtures here go one step
further: they're whole AVM modules that real binaries can run end-to-end
when a contributor wants to manually validate the verb chains on a bare
workstation (`./build.ps1 doctor && avm pre-commit -Ecosystem terraform -Path tests\fixtures\modules\<name>`).

## What's here

| Fixture                              | Provider(s)                                  | Purpose                                                                                            |
| ------------------------------------ | -------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `terraform-azurerm-avm-res-mock/`    | `hashicorp/azurerm` + `azapi` + `modtm` + `random` | Mock AVM resource module with two examples (`default`, `default-ignore`) and a `tests/unit/` `tftest.hcl`. Validates the full `format → lint → test → docs` + `check policy` chain. |
| `terraform-azure-avm-res-mock/`      | `Azure/azure` (AzAPI-only) + `modtm`         | Mock AVM resource module with **three** examples (`default`, `ignored_example`, `second_example`), per-example lifecycle hooks (`pre/post/tflint-pre.{sh,ps1}`), example-level setup/teardown (`examples/setup\|teardown.{sh,ps1}`), and **both** `tests/unit/` *and* `tests/integration/` `tftest.hcl` (with `setup.{sh,ps1}` companions). Exercises the broader engine surface — lifecycle hooks, integration test discovery, multi-example sorting. |

## Source

Both fixtures were copied from
[`Azure/avm-terraform-governance`](https://github.com/Azure/avm-terraform-governance)
at commit `7f8c4ee4d68095310ddd8722f9cc27d32a0de82c` (default branch
`main`, 2026-06-16). Upstream paths:

- `tests/terraform-azurerm-avm-res-mock/` → `terraform-azurerm-avm-res-mock/`
- `tests/terraform-azure-avm-res-mock/` → `terraform-azure-avm-res-mock/`

Upstream is MIT-licensed (Azure org). The repo-root `LICENSE` covers the
copied content; no per-fixture `LICENSE` shipped.

This SHA matches the governance modules verbatim (modulo the curation
drop-list below and LF/UTF-8-no-BOM normalisation), so the fixtures are
"the same modules" the upstream pipeline runs against. Relative to the
prior `651824…` snapshot the refresh added two files that are now part of
the canonical AVM Terraform surface — `variables.example.tf` and
`variables.telemetry.tf` (the telemetry/example variables that the
`mapotf` `pre-commit` configs partition out of `variables.tf`) — and
refreshed the content of `main.tf`, `main.telemetry.tf`, `outputs.tf`,
`variables.tf`, the module `README.md`, and `tests/unit/unit.tftest.hcl`.

## What was dropped on copy

Each upstream mock module is a full repository skeleton. Only the
Terraform module surface is needed here; everything that exists to bootstrap
the upstream governance pipeline was removed:

- Legacy AVM shim scripts (`avm`, `avm.bat`, `avm.ps1`) — replaced by the
  `Avm.Authoring` CLI in this repo.
- `Makefile` — replaced by `./build.ps1` and the `avm` verbs.
- Repository boilerplate (`LICENSE`, `AGENTS.md`, `CODE_OF_CONDUCT.md`,
  `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`) — would shadow or
  confuse this repo's own copies.
- Editor / tooling metadata (`.editorconfig`, `.devcontainer/`,
  `.github/`, `.agents/`, `.vscode/`, module-level `.gitattributes`) —
  fixture isn't an editable project, and our repo-wide `.gitattributes`
  already enforces LF + UTF-8.
- All `.gitkeep` files — every directory we kept has at least one real
  file, so the markers are redundant.

The result is the AVM-shape Terraform surface plus, in the `azure`
variant, the lifecycle / setup hooks and integration-test fixture that
exist in the upstream mock.

### Kept on purpose: `.gitignore`

Each fixture **does** keep its module-level `.gitignore` (copied verbatim
from upstream — the same 24-glob canonical AVM line set). It is *not*
dropped like the rest of the editor/tooling metadata because
`avm check convention` ships a built-in rule — `avm.tf.gitignore-essentials`
(`src/Avm.Authoring/Resources/Rules/030-gitignore-essentials.psd1`,
severity `error`) — that fails a module whose root `.gitignore` is missing
any of those globs. Dropping `.gitignore` would make the fixture
non-compliant against our own convention chain, so the real-binary
`pre-commit` / `pr-check` smoke (`tests/Pester/Smoke/`) would report
`check convention = fail`. Keeping it lets both chains go green
end-to-end. Refresh it together with the rest of the module surface.

## Refreshing from upstream

When upstream changes meaningfully (provider major bump, telemetry
contract change, new example shape):

```pwsh
# 1. Shallow-clone upstream into a temp folder with autocrlf off.
git -c core.autocrlf=false clone --depth 1 --filter=blob:none --sparse `
    https://github.com/Azure/avm-terraform-governance.git "$env:TEMP\avm-tfgov-snapshot"
git -C "$env:TEMP\avm-tfgov-snapshot" sparse-checkout set `
    tests/terraform-azurerm-avm-res-mock `
    tests/terraform-azure-avm-res-mock

# 2. Re-curate the keep list (see top of this README) and copy by path.
#    Drop the same governance/legacy/editor noise listed above.

# 3. Run `./build.ps1 pre-commit` — should stay green (fixtures live
#    outside the build's scan scope).

# 4. Bump the source SHA in this README's "Source" section and commit
#    with a Conventional `test(fixtures): refresh …` message.
```

The `.gitattributes` rules at repo root force LF + UTF-8 (no BOM) on
`*.tf`, `*.md`, `*.yml`, `*.hcl`, `*.sh`, `*.ps1` etc., so the on-disk
encoding will be correct as long as the source clone was made with
`core.autocrlf=false`.

## What isn't here yet

- Porting `Invoke-AvmPreCommit.Terraform.Integration.Tests.ps1` from
  its current TestDrive scaffold onto either of these fixtures. Separate
  follow-up slice; the existing test still has value as a hermetic
  fixture-builder smoke.
- A keyvault-flavoured fixture (`terraform-azurerm-avm-res-keyvault-vault`
  per the Phase 2 §3 demo deliverable in `docs/progress.md`). That
  module is real (not a mock) and would pull live provider downloads;
  add when the demo slice itself is ready.
