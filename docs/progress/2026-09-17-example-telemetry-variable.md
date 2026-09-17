# Example telemetry variable

**Status**: complete
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-example-telemetry-variable`

## Outcome

Use `enable_telemetry = var.enable_telemetry` on example module calls whose
source declares exactly that input. Reuse the example's existing declaration
wherever it lives, preserving its metadata while ensuring `default = false`,
including for formerly required inputs. If absent, append a bool declaration
with a false default to `variables.tf`, creating the file only when needed.

Unsupported modules and examples without relevant calls remain unchanged.
Keep source-module defaults, root/submodule call sites, profile ordering,
overrides, comments, idempotence, `-WhatIf`, and drift snapshot restoration.
Implement source inspection and edits in MaPoTF HCL, not PowerShell parsing.

## Checklist

- [x] Read repository contracts and active progress; start from current main.
- [x] Rename the new feature branch and check for an existing matching request.
- [x] Implement supported-call references and conditional variable reuse/creation.
- [x] Cover declaration defaults, comments, inline HCL, multiple files/calls,
      unsupported modules, overrides, dry runs, and drift restoration.
- [x] Prove the unused-variable regression with pinned TFLint and validate
      provider-free examples with real MaPoTF and Terraform.
- [x] Update five canonical examples, generated README output, and related docs.
- [x] Run focused checks, the dedicated integration suite, and the full local gate.
- [x] Prepare the validated slice for commit, push, and review.

## Validation

- `.\build.ps1 pre-commit`: 1,551 unit tests passed with eight skips;
  597 component tests passed with one skip. Zero failures, zero build errors,
  and 34 build warnings. Runtime: 10m 57s.
- `.\build.ps1 integration -TestName 'Integration: MAPOTF example telemetry*'`:
  40 passed, zero failed or skipped. Runtime: 9m 47s.
- Focused unit checks: 48 passed, zero failed or skipped.
- Pinned TFLint 0.64.0 reproduces `terraform_unused_declarations` before repair
  for one and two module calls, then reports no issues after repair. These
  provider-free fixtures also pass Terraform 1.15.8 validation.
- Real MaPoTF 0.2.1 coverage includes supported/unsupported inputs, expressions,
  exact variable names, required/true/null/string-false defaults, metadata,
  comments, safe append boundaries, inline variables/calls, multiple files,
  first-pass ordering, idempotence, `-WhatIf`, and drift snapshot restoration.
- All five canonical examples and their generated README files are unchanged
  by the final profile and terraform-docs 0.24.0 regeneration.
- Logs and NUnit reports are retained in the session artifact directory.
  The full gate reports warnings from existing test scenarios, including
  permitted catalog row removals and disabled BAMI activation. No Azure
  deployment, production operation, or OS-setting change was run.

## Implementation notes

Existing inline defaults use MaPoTF's scalar-safe update mode; only inline
declarations missing a default are expanded before insertion. Common variable
ordering now skips inline blocks, which have no argument order to change and
could otherwise become invalid HCL with MaPoTF 0.2.1.

Supported call values are written as HCL references idempotently. A string
literal containing `var.enable_telemetry` must not be mistaken for the reference
itself. Exact-name declaration checks prevent duplicate variables, while typed
default comparisons also replace string-valued false defaults with bool false.

## Blockers and dependencies

None. The earlier implementation is merged in
[#128](https://github.com/Azure/azure-verified-modules-tools/pull/128).
The parent session owns inspection of
[Azure/terraform-azurerm-avm-res-azurestackhci-logicalnetwork#149](https://github.com/Azure/terraform-azurerm-avm-res-azurestackhci-logicalnetwork/pull/149)
and supplied its existing true-default/heredoc declaration and
`# see variables.tf` call-site comment as regression inputs.
