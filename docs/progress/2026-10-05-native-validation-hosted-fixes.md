# Native validation hosted fixes

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Correct failures exposed by hosted run `37360979472` on `248b096`:
Pester dependency name-check warnings leaked into metadata/catalog results;
integration did not build the package required by installed-package acceptance;
policy acceptance cleanup assumed setup had completed.

## Checklist

- [x] Disable name checking at Pester dependency imports, not globally.
- [x] Build the package once through the integration task dependency.
- [x] Preserve other output artifacts when rebuilding the package.
- [x] Make early setup failure cleanup safe.
- [x] Run focused safe acceptance and the full gate.
- [x] Commit and push this fix separately from the compiled assertion migration.

## Validation

The parent's saved Ubuntu logs identify 62 metadata-authoring and eight catalog
failures caused by the same dependency warning. No warning assertions or global
warning preferences were weakened.

- Full working-tree `build.ps1 pre-commit`, including the concurrent compiled
  slice, with Pester 6.2.0: 3,001 unit passed / nine skipped; 1,497 component
  passed / one skipped; layout and lint green.
- `build.ps1 integration` selecting only packaged metadata and policy: seven
  passed on both Pester 5.7.1 and 6.2.0. Task output confirms layout, build, then
  integration; earlier test-result/log directories survive staging.
- Pester 5.7.1 focused native/component compatibility: 153 passed / one skipped.
- The new missing-package child-process regression proves setup fails explicitly
  with no secondary cleanup failure. It also exposed Pester 6 failed blocks
  lacking `Item`; diagnostic translation now guards that optional property.

Pester 6.2.0 was restored only to the session directory after the explicit
versioned validation attempt reported it missing. No global dependency upgrade,
broad integration run, Azure operation, or host-security change.
