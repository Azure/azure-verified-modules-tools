# Initialize module ShouldProcess correction

**Status**: complete
**Started**: 2026-09-26
**Updated**: 2026-09-26
**Branch**: `jaredfholgate-interactive-metadata-initialization`

## Outcome

Fix the hosted PowerShell lint warning on `Initialize-AvmModule` without
changing metadata initialization, its WhatIf plan, or its single-confirmation
behavior. The wrapper should confirm a new write once and delegate with
confirmation disabled; existing metadata and WhatIf still flow through the
validated, non-writing metadata initializer.

## Checklist

- [x] Locate the hosted lint warning and distinguish it from analyzer retries.
- [x] Make the wrapper call ShouldProcess for new metadata and prevent a second
      confirmation in the delegated initializer.
- [x] Cover WhatIf and single-confirmation behavior in component tests.
- [x] Run the repository pre-commit gate, commit, and push the correction.

## Validation

The original hosted lint run reported PSShouldProcess for
`Initialize-AvmModule.ps1` after transient analyzer retries. Local lint now
reports no findings and all 20 focused local-initialization component tests
pass. `./build.ps1 pre-commit` passed layout, lint, 1,837 unit tests (9
skipped), and 845 component tests. Its 49 warnings are emitted by existing
test fixtures. Hosted lint is checked separately after this change is pushed.

## Blockers and dependencies

The separate Bicep format drift-check slice waits for the hosted lint result.
