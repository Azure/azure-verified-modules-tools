# Terraform CODEOWNERS generation

**Status**: complete
**Started**: 2026-09-14
**Updated**: 2026-09-14
**Branch**: `jaredfholgate-terraform-code-owners`

## Outcome

Restore Terraform module CODEOWNERS generation in the existing repository-sync
flow. Render the configured default and file-protection teams from
`repository-config/config.json`, and replace the retired governance header with
the authoritative template link in this repository.

The ownership settings survived the retirement of
`github_repository_file.codeowners`, but no replacement consumed them to render
the file. The sync driver now passes both resolved team lists to its PowerShell
preparation adapter instead of unused Terraform variables. Matching wildcard,
overlapping, and single-repository groups retain their existing union semantics.
The migration snapshot had team-based default and file-protection settings, not
individual-owner or path-specific mappings.

## Checklist

- [x] Confirm the ownership inputs and shared synchronization contract.
- [x] Restore the template and generation without a separate publication path.
- [x] Cover default ownership, file protection, plan-only behavior, and drift
      repair with offline regression tests.
- [x] Document the source of truth and update process.
- [x] Run the required local gate and record its diagnostic caveat.
- [x] Prepare the validated change for commit and review.

## Validation

- `.\build.ps1 test-repository-management`: 229 passed, none failed.
- `.\build.ps1 component`: 93 passed, none failed.
- `.\build.ps1 pre-commit`: exited 0; layout and lint completed, 1,274 unit
  tests passed and 93 component tests passed. The unit run also reported eight
  skipped tests, one not run, and a teardown failure in the unchanged
  `Invoke-AvmTerraformTest` suite: `Collection was modified; enumeration operation
  may not execute.` The build task does not turn that teardown diagnostic into a
  nonzero exit. This is not a claim that the entire suite was clean.
- Regression coverage includes configured tier and repository-specific teams,
  unrelated-group isolation, default/file-protection rule ordering, malformed
  input, corrected source comments, missing files/directories, byte-stable LF
  output without BOM, filesystem conflicts, no writes after failed preparation,
  and unchanged shared publication and plan-only behavior.

No live repository synchronization, Terraform apply, workflow dispatch,
permission change, or module-repository mutation was performed.

## Blockers and dependencies

No implementation blockers. Hosted CI must pass before merge; the unrelated
unit-suite teardown diagnostic above was not addressed by changing module code,
the test runner, or workstation dependencies.

The internal `Azure-Verified-Modules-Docs` repository-sync runbook should also
document the restored template location and repository-group ownership settings.
