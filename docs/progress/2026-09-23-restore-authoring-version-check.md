# Restore Avm.Authoring version checks

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-avm-authoring-upgrade-prompts`

## Outcome

Require the latest PowerShell Gallery version for normal Avm.Authoring commands
again. `avm version` and `Get-AvmVersion` still return version information, but
warn when an update is available. Explicit `-SkipModuleVersionCheck` remains
available to unattended Bicep automation.

## Checklist

- [x] Restore the version comparison, typed failure, and actionable upgrade guidance.
- [x] Make version reporting warn without blocking and keep `avm update` usable.
- [x] Restore the repository sync's upgrade-and-retry behavior.
- [x] Cover enforcement, opt-out, warning-only version reporting, and offline behavior.
- [x] Update the directly related module documentation.
- [x] Run the local pre-commit gate, commit, and push.

## Validation

- Focused Pester version/dispatcher suite: 44 passed.
- `Test-AvmPreCommit.ps1`: passed (upgrade retry and non-version failure).
- `./build.ps1 pre-commit`: 1755 unit tests passed, 907 component tests
  passed, no test failures. Existing analyzer and fixture warnings did not
  fail the gate.
- Live source-module checks against PowerShell Gallery 0.17.1: `avm version`
  returned version 0.0.0 with one update warning; `avm help` rejected the
  outdated source build with `AVM1050`.

## Dependencies

The Bicep repository's metadata test runner already passes
`-SkipModuleVersionCheck`; its workflow tests assert this. Its daily
module-list sync does not call Avm.Authoring, so no Bicep repository change is
required. The retired tools-repository Bicep CODEOWNERS sync no longer runs.
