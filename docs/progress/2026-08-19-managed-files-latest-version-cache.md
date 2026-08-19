# Managed-files latest-version cache

**Status**: complete
**Started**: 2026-08-19
**Updated**: 2026-08-19
**Branch**: `jaredfholgate-fix-managed-files-version`

## Outcome

Ensure every managed-file operation discovers the current highest published
semver tag, rather than reusing a version cached by an earlier `avm` command in
the same PowerShell session.

## Checklist

- [x] Remove the module-lifetime latest managed-files version cache.
- [x] Add a regression test for observing a newly published tag in one session.
- [x] Run targeted validation and the live tag lookup.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit, push, and open a pull request.

## Validation

- `./build.ps1 test`: 977 passed, 0 failed, 8 skipped.
- `./build.ps1 pre-commit`: layout and lint passed; 977 unit tests passed
  with 8 skipped; 28 component tests passed.
- The regression test returns `1.0.8` from its first simulated tag listing and
  `1.0.10` from its second listing in the same module session.
- Two consecutive lookups against
  `Azure/azure-verified-modules-managed-files` both returned `1.0.10`.
- `git diff --check`: passed.

## Dependencies and blockers

None.
