# Managed files: strip the `terraform-azure-` repository prefix

**Status**: complete
**Started**: 2026-09-08
**Updated**: 2026-09-09
**Branch**: `fix/managed-files-terraform-azure-prefix`

## Outcome

`ConvertTo-AvmManagedFilesRepoId` normalises a repository name into a
managed-files repository id by stripping the leading Terraform provider prefix.
It stripped `terraform-azurerm-` and `terraform-azapi-` but not
`terraform-azure-`, the convention used by `Azure/azure` (AzAPI) provider
modules.

A repository named `terraform-azure-...` therefore kept its prefix, never
matched its `repositoryGroups` entry in
`repository-management/repository-config/config.json`, and silently fell back to
the root-only file set. Three repositories in the `azure-landing-zones` group
carry that prefix — `avm-ptn-alz-sub-vending` and the two ALZ CI/CD bootstrap
repositories — and for all three `avm sync` wants to add the generic AVM issue
forms and overwrite the centralised ALZ issue-routing `config.yml`, the opposite
of what the `alz` overlay declares.

Add `terraform-azure-` to the prefix list so automatic inference resolves these
repositories to the same id an explicit `repoId` override already produces.

## Why this is an oversight rather than a deliberate exclusion

- This repository's own canonical integration fixture is named
  `terraform-azure-avm-res-mock`, wired into `.github/workflows/ci.yml`, the
  layout tests, the integration tests and `tests/fixtures/modules/README.md`.
  The convention is already recognised everywhere except this one function.
- `config.json` explicitly lists
  `avm-ptn-alz-sub-vending`,
  `avm-ptn-alz-application-landing-zone-cicd-bootstrap-github` and
  `-azure-devops` in the `azure-landing-zones` group with
  `managedFiles: ["alz"]`, so the intent to manage them is declared. Only the
  normalisation step prevents it.
- Group ids in `config.json` carry no `terraform-` prefix at all, so the
  configuration format is prefix-agnostic by design.
- The list originates in `20afcf8`, "remediate the 18 Avm.Authoring 0.1.4
  end-to-end findings (F01-F18)", item F11 — a batch remediation rather than a
  naming-policy decision.
- The function's own synopsis describes stripping "the terraform provider
  prefix", not a curated pair.

## Checklist

- [x] Confirm the omission is an oversight, not a deliberate naming policy.
- [x] Add `terraform-azure-` to the prefix list.
- [x] Update the four doc comments that enumerate the accepted prefixes.
- [x] Add regression coverage for the new prefix and for the two existing ones.
- [x] Run the local pre-commit gate.

## Validation

Reproduced and verified with `avm sync -CheckDrift` against every repository in the
`azure-landing-zones` group of `config.json` that carries an affected prefix, plus two
`terraform-azurerm-` repositories as regression controls. The "before" runs used the
released module; the "after" runs imported this working tree directly via
`src/Avm.Authoring/Avm.Authoring.psd1`, so the evidence covers the code as committed
rather than a patched copy of it. None of the repositories carries a
`.avm/managed-files.json` override, so automatic inference is genuinely exercised.

Three of the seven repositories in the group carry the `terraform-azure-` prefix:
`avm-ptn-alz-sub-vending` and the two `-cicd-bootstrap-` repositories. The other four
are `terraform-azurerm-` and were never affected.

| Repository | Prefix | Before | After |
| --- | --- | --- | --- |
| `...-cicd-bootstrap-github` | `terraform-azure-` | fail, 57 files, 2 added / 1 updated, 3 issues | pass, 55 files, no drift |
| `...-cicd-bootstrap-azure-devops` | `terraform-azure-` | fail, 57 files, 2 added / 1 updated, 3 issues | pass, 55 files, no drift |
| `...-alz-sub-vending` | `terraform-azure-` | fail, 62 files, 4 added / 1 updated, 5 issues | 60 files, 2 added, 2 issues — see below |
| `terraform-azurerm-avm-ptn-cicd-agents-and-runners` | `terraform-azurerm-` | pass, 69 files | pass, 69 files, unchanged |
| `terraform-azurerm-avm-ptn-alz` | `terraform-azurerm-` | pass, 62 files | pass, 62 files, unchanged |

The two bootstrap repositories drop from 57 processed files to 55 because the `alz`
overlay's `_config.json` deletes the two generic AVM issue forms. 55 is exactly the
count an explicit `repoId` override already produced before this change, so automatic
inference now matches the override rather than merely passing.

`avm-ptn-alz-sub-vending` has its overlay-selection drift resolved — both AVM issue
forms and the `config.yml` update disappear, and its file count falls by the same two —
but it does not reach a clean sync. The two remaining entries are
`.vscode/extensions.json` and `.vscode/settings.json`, reported as missing managed
files. That repository is pinned to managed-files `1.0.18` while the bootstrap
repositories are on `1.0.27`; it is behind on its own sync, and that drift is unrelated
to this change and persists with or without it.

The two `terraform-azurerm-` repositories are byte-identical before and after, which is
the regression control: the new prefix cannot mis-strip the longer ones because the
trailing hyphen makes them disjoint.

`./build.ps1 pre-commit` passed: layout, lint, 1,037 unit tests (8 skipped) and 29
component tests, 0 errors. The baseline on `main` before this change was 1,036 unit
tests, so the delta is exactly the one new test, which was confirmed by name in the
run output rather than inferred from the count. `git diff --check` passed. No Azure
resources were involved and none are needed — the whole code path is a repository-name
string, a `config.json` lookup and a file comparison on disk.

## Blockers and dependencies

None. No configuration, release or downstream change is required — repositories
already listed in `config.json` start resolving correctly as soon as a build
carrying this change is used.
