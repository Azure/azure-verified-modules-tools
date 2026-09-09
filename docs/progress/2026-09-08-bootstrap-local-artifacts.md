# Local-only bootstrap artifacts

**Status**: complete
**Started**: 2026-09-08
**Updated**: 2026-09-08
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Remove `infra/tme.outputs.json` and `infra/.terraform.lock.hcl` from the tracked
tree, preserve local copies, and ignore both. Fresh validation must initialize
without a checked-in provider lock. Preserve the deployed TME infrastructure
and leave live repo-sync state/configuration unchanged.

## Checklist

- [x] Untrack and ignore both generated files without deleting local copies.
- [x] Remove readonly-lock assumptions and document local output recovery.
- [x] Validate a fresh init and complete the local gate for the existing branch.

## Validation

- `.\build.ps1 infra` passed with both generated files temporarily absent;
  original local copies were restored with matching hashes afterward.
- `.\build.ps1 test-repository-management`: 59 passed.
- `.\build.ps1 pre-commit` passed; existing module analyzer warnings remain.
- Regression coverage asserts both paths are ignored and absent from Git's
  index. README PowerShell snippets parse without running Azure commands.

## Blockers or dependencies

No deployment, state migration, or Git history rewrite is required.
