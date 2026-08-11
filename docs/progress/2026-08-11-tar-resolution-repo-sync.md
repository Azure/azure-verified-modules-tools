# Tar resolution breaks repository sync

Status: complete
Started: 2026-08-11
Updated: 2026-08-11
Completed: 2026-08-11
Branch: jaredfholgate-fix-repo-sync-tar-resolution

## Outcome

Restore `Repository Management - Repository Sync` on Linux runners, where installing
any `tar.gz` pinned tool (the first is `mapotf`) aborted the job.

`Expand-AvmToolArchive` resolved the native `tar` binary with
`Get-Command -Name 'tar' -CommandType Application` and no `Select-Object -First 1`.
On Ubuntu runners `/bin` is a symlink to `/usr/bin` and both directories are on
`PATH`, so the lookup returns two `ApplicationInfo` objects. Member enumeration then
made `$tar.Source` a `string[]`, which cannot bind to `Invoke-AvmProcess -FilePath`
(`[string]`), producing:

```
Cannot process argument transformation on parameter 'FilePath'.
Cannot convert value to type System.String.
```

Every other `Get-Command -CommandType Application` call in the module already
selects a single result; this call site was the outlier.

## Checklist

- [x] Select a single `tar` result and guard against an empty `Source`.
- [x] Cover multi-result `tar` resolution with a unit test.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit, push, and open a pull request.

## Validation

- `./build.ps1 pre-commit`: layout, lint, and unit tiers green.
- `./build.ps1 component`: 28 passed, 0 failed, 0 skipped.
- Linux verification under WSL `Ubuntu-24.04` (PowerShell 7.4.6, Pester 5.7.1) because
  the defective branch never runs on Windows: the new test fails with the exact CI
  binding error when the fix is reverted and passes once it is restored.
- The governance guard fix from
  <https://github.com/Azure/azure-verified-modules-tools/pull/62> is merged into this
  branch so `MigrationLayout.Tests.ps1` passes here; PR 62 is closed in favour of this one.
- Failing run for reference:
  <https://github.com/Azure/azure-verified-modules-tools/actions/runs/31543072003/job/93949748137>

## Blockers or dependencies

- None.
