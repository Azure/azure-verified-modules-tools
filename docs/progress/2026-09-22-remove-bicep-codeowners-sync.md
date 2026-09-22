# Remove Bicep CODEOWNERS sync

Status: complete
Branch: jaredfholgate-fix-bicep-sync-workflow
PR: #168 (https://github.com/Azure/azure-verified-modules-tools/pull/168)

## Outcome

Following the earlier fix to the `repository-management-bicep-sync.yml` workflow
(stale stable-branch bug), the decision was made to stop managing the Bicep
`.github/CODEOWNERS` file from this workflow entirely, rather than continuing to
fix its bugs. The BAMI test-tenant sync (`sync-test-tenant-variables` job) is
unaffected and remains fully in place. Terraform CODEOWNERS management
(`repository-management/repository-sync`) is a separate, independent feature
and was not touched.

## Checklist

- [x] Deleted `repository-management/bicep-codeowners-sync/` (module, template,
      local export script) and `docs/bicep-codeowners-sync.md`.
- [x] Removed the `sync` (CODEOWNERS) job and the `schedule:` trigger from
      `.github/workflows/repository-management-bicep-sync.yml`; the BAMI job is
      `workflow_dispatch`-only so nothing else needed the schedule.
- [x] Removed the now-stale path filter from
      `.github/workflows/repository-management-config-test.yml`.
- [x] Removed/rewrote unit and component tests that exercised the deleted
      `Invoke-AvmBicepCodeownersSync` / `Get-AvmBicepCodeownersSnapshot` /
      `Test-BicepCodeownersSyncChange` functions, while keeping the generic
      shared-publisher (`Invoke-RepositoryFileSync`) and Terraform CODEOWNERS
      coverage intact.
- [x] Added a negative-assertion test confirming the workflow no longer
      schedules or manages Bicep CODEOWNERS.
- [x] Updated `docs/metadata-rollout.md` with a note that the feature was
      removed.
- [x] Ran `./build.ps1 pre-commit`.

## Follow-ups

- `Azure/bicep-registry-modules#7357` (branch `avm-bot/bicep-codeowners-sync`)
  is a stale bot PR from the original bug; it is now orphaned since CODEOWNERS
  management is gone. Flagged to the user for a decision on closing it (a
  cross-repository, production action requiring explicit confirmation).
