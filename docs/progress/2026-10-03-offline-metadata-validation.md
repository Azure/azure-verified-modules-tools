# Offline metadata validation

**Status**: complete
**Started**: 2026-10-03
**Updated**: 2026-10-03
**Branch**: `jaredfholgate-offline-metadata-validation`

## Outcome

Changed the packaged metadata schema to the canonical HTTP draft-07 identifier,
which `Test-Json` resolves from its bundled meta-schema instead of downloading
it. This is a local identifier lookup, not an unencrypted HTTP request.
Authored metadata references and validation rules are unchanged.

## Checklist

- [x] Read repository guidance and confirm current main still has the defect.
- [x] Reproduce the failure in an isolated offline component regression.
- [x] Use the canonical draft-07 identifier and preserve invalid-data rejection.
- [x] Run the focused metadata checks and local pre-commit gate.
- [x] Record validation and the release dependency for handoff.

## Validation

On PowerShell 7.6.6, the regression uses the real public validator in fresh
PowerShell processes with .NET's default proxy pointing to a reserved,
non-listening loopback port. It does not mock `Test-Json` or change the parent
process, machine, or user proxy configuration.

Before the schema change:

```powershell
.\build.ps1 component -TestName '*validates metadata without network access*'
```

All four Bicep/Terraform root/child cases failed with `AVM_METADATA_SCHEMA` and
`Cannot parse the JSON schema.`, reproducing the reported defect.

After the schema change:

```powershell
.\build.ps1 pre-commit -TestName @(
    'Terraform metadata source wiring*'
    'Strict metadata JSON*'
    'Metadata owner uniqueness*'
    'Bicep literal metadata reader*'
    'Bicep metadata source planning*'
    'Metadata ARM resource classification*'
    'Metadata module identity*'
    'Component: child helper metadata*'
    'Component: metadata property order*'
    'Component: Oracle metadata compatibility*'
    'Component: shared module metadata schema*'
    'Component: permanent metadata reader*'
    'Component: non-overwriting metadata initialization*'
    'Component: metadata in authoring checks*'
)
```

Passed layout, lint, 88 unit tests, and 344 component tests, with zero failures
or skips. All four isolated offline cases passed; each also requires missing
`canonicalType` to remain an `AVM_METADATA_SCHEMA` failure. Existing strict
root/child shapes, ownership, telemetry, source checks, initialization, and
authoring-chain behavior remain covered.

`git diff --check` passed. No dependencies were installed, and no native-tool
integration tests or cloud tests were needed.

## Blockers or dependencies

No implementation blockers. Consumers receive the fix after a separately
authorized Avm.Authoring release. No deployment, publishing, installed-module
changes, or other repository changes are in scope.
