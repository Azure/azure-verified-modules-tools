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
| `terraform-azure-avm-res-mock/`      | `Azure/azure` (AzAPI-only) + `modtm`         | Mock AVM resource module with **three** examples (`default`, `ignored_example`, `second_example`), all three TFLint override variants, PowerShell lifecycle hooks, dotenv input, example-local policy exceptions, an adversarial Event Hub policy violation, and **both** `tests/unit/` *and* `tests/integration/` `tftest.hcl`. Exercises override merging, policy isolation, lifecycle hooks, integration discovery, and multi-example sorting. |

## Source

Both fixtures were copied from
legacy Terraform governance repository
at commit `7f8c4ee4d68095310ddd8722f9cc27d32a0de82c` (default branch
`main`, 2026-06-16). Upstream paths:

- `tests/terraform-azurerm-avm-res-mock/` → `terraform-azurerm-avm-res-mock/`
- `tests/terraform-azure-avm-res-mock/` → `terraform-azure-avm-res-mock/`

Upstream is MIT-licensed (Azure org). The repo-root `LICENSE` covers the
copied content; no per-fixture `LICENSE` shipped.

The snapshot matched the governance modules verbatim (modulo the curation
drop-list below and LF/UTF-8-no-BOM normalisation). The Azure fixture now
has one deliberate local compatibility delta: its AzAPI resource declarations
use the canonical `resource_types` interface and `variables.tf` carries the
v0.19 required AzAPI interfaces. The upstream governance fixtures were retired
after the Avm.Authoring rollout, while the copies here remain authoritative.

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
from upstream). It is *not* dropped like the rest of the editor/tooling
metadata because it is genuine module content that the managed-files
engine maintains through the `managedLines` line spec in the governance
repository's `terraform/root/_config.json`. Keeping it lets the
real-binary `pre-commit` / `pr-check` integration
(`tests/Pester/Integration/`) exercise the line-merge path against a
realistic starting file. Maintain it together with the rest of the
fixture surface.

## Maintaining the fixtures

The copies in this repository are authoritative. Update them in a focused
change when a provider major, telemetry contract, or example shape changes,
preserve the curation boundaries above, and run `./build.ps1 pre-commit`.

The `.gitattributes` rules at repo root force LF + UTF-8 (no BOM) on
`*.tf`, `*.md`, `*.yml`, `*.hcl`, `*.sh`, `*.ps1` etc., so the on-disk
encoding remains deterministic.

## What isn't here yet

- Porting `Invoke-AvmPreCommit.Terraform.Integration.Tests.ps1` from
  its current TestDrive scaffold onto either of these fixtures. Separate
  follow-up slice; the existing test still has value as a hermetic
  fixture-builder smoke.
- A keyvault-flavoured fixture (`terraform-azurerm-avm-res-keyvault-vault`
  per the Phase 2 §3 demo deliverable in `docs/progress.md`). That
  module is real (not a mock) and would pull live provider downloads;
  add when the demo slice itself is ready.
