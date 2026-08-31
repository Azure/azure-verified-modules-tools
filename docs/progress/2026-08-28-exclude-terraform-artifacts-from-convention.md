# Exclude .terraform build artifacts from convention scope discovery

**Status**: complete
**Started**: 2026-08-28
**Updated**: 2026-08-28
**Branch**: `agents/fix-issue-85`

## Outcome

`avm check convention` stops reporting `avm.tf.terraform-scopes-must-be-direct-children` against downloaded module copies under `.terraform/`. Reported in [issue #85](https://github.com/Azure/azure-verified-modules-tools/issues/85).

`terraform init` writes `.terraform/modules/<name>/` for every scope that sources an external module, so any scope pulling `avm_interfaces` gains a tree of `*.tf` files two or more levels below `modules/` or `examples/`. The scope rule walked that tree and read each copy as an authored nested root. `avm test unit` runs `terraform init`, so running it before `pr-check` in the same worktree was enough to trigger the failure — and because the directories are correctly gitignored, they are invisible to `git status`. Stale ones persist across sessions, which is how the reporter hit it against a branch authored ten days earlier. On `Azure/terraform-azurerm-avm-res-web-site` this produced 9, 47 and ~19 errors on three separate occasions, none of them actionable.

The fix prunes rather than filters. `Get-AvmDescendantDirectory` walks with an explicit stack and never descends into an excluded directory, so a populated `.terraform` costs one predicate call instead of a walk over every module it downloaded.

The exclusion predicate is "any path segment starting with `.` or named `node_modules`", relative to the walk root. That is the same rule `Get-AvmTerraformFile` and `Invoke-AvmTerraformTest` already apply inline, so `.terraform` is covered along with `.git`, `.avm`, and the rest, and the codebase gains one named helper instead of a third copy of the expression. Reading `.gitignore` itself was rejected: it would make convention results depend on repository-specific ignore rules, and every case actually observed is a dot-directory.

`Get-AvmRuleTargetRoot` got the same exclusion. `terraform init` run directly in `examples/` or `modules/` leaves a `.terraform` there, which would otherwise be expanded into a rule target and fail every `AppliesTo = 'examples'` rule for a directory nobody authored.

## Checklist

- [x] Add `Test-AvmIgnoredPath` to `src/Avm.Authoring/Private/Folders/`.
- [x] Add `Get-AvmDescendantDirectory` to the same folder, pruning excluded subtrees during the walk.
- [x] Use it in `Test-AvmRuleTerraformScopesMustBeDirectChildren`, replacing `Get-ChildItem -Recurse`.
- [x] Apply the same exclusion to the `examples` and `modules` branches of `Get-AvmRuleTargetRoot`.
- [x] Give the scope primitive a comment-based help block; it had none.
- [x] Add `tests/Pester/Unit/Private/Test-AvmIgnoredPath.Tests.ps1` covering both helpers.
- [x] Add regression cases to the primitive and engine test files.
- [x] Add the `### Fixed` bullet under `## [Unreleased]` in `CHANGELOG.md`.

## Validation

- `tests/Pester/Unit/Private/Test-AvmIgnoredPath.Tests.ps1`: 13 passed. Covers the ignore predicate in both directions — `node_modules_helper` and `modules/terraform-things/main.tf` must not match a prefix test — plus the root-is-never-ignored case, which matters because a caller may legitimately choose a path below a dot directory as its walk origin.
- `tests/Pester/Unit/Private/Rules/Primitives/Test-AvmRuleTerraformScopesMustBeDirectChildren.Tests.ps1`: 4 passed. One case asserts the artifacts are ignored; a second pairs an authored `modules/network/private/main.tf` against a `.terraform` copy in the same scope, so the rule is proven to still fire rather than to have been switched off.
- `tests/Pester/Unit/Private/Engines/Invoke-AvmTerraformCheckConvention.Tests.ps1`: 20 passed. Reproduces the reported shape end to end (`modules/slot/.terraform/modules/avm_interfaces/`, `examples/default/.terraform/`) and asserts `Status = 'pass'`, plus a case for `.terraform` sitting directly under `examples/` and `modules/`.
- `./build.ps1 pre-commit`: layout, lint, test and component legs green.
