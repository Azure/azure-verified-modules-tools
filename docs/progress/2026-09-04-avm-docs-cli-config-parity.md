# AVM docs CLI configuration parity

**Status**: complete
**Started**: 2026-09-04
**Updated**: 2026-09-04
**Branch**: `jaredfholgate-avm-docs-cli-config-parity`

## Outcome

Keep the AVM README parity and semantic model-index diagnostics working with
the Bicep docs contract that resolves template files and include roots only
from discovered `bicepconfig.json` settings.

## Checklist

- [x] Remove template file and include-root CLI overrides.
- [x] Keep custom template values invocation-only.
- [x] Preserve parallel all-module execution without shared config mutation.
- [x] Restore the working checkout configuration after validation.
- [x] Acquire the cross-process lock before snapshotting configuration.
- [x] Replace and restore configuration atomically.
- [x] Update documentation and tests.
- [x] Run targeted validation and the pre-commit gate.

## Validation

- Candidate CLI full validation against AVM commit `96a1dcb69` covered 573
  eligible modules: 572 READMEs generated and all 572 matched byte-for-byte.
  The final post-safety-fix run completed in `00:06:53.2345760` using executable
  SHA256 `108B1574FC6361D9A251D7BF4B3AF6632162B9791FD62749865F8A8A0E737A19`.
- The retained compiler failure was
  `avm/ptn/app/container-job-toolkit`. The diagnostic workflow also retained
  nine known parameter-model differences and one upstream README/test-metadata
  example drift in `conversation-knowledge-mining`.
- Regression tests cover lock-before-snapshot ordering, a stable lock outside
  the checkout with Windows case normalization, exact-byte restoration, and
  preservation of the original file when atomic replacement fails.
- `./build.ps1 pre-commit` passed after the configuration safety fixes.

## Dependencies

- Candidate Bicep CLI build from `Azure/bicep` commit `e2defed7d`.
- Draft Bicep PR: https://github.com/Azure/bicep/pull/20269.
