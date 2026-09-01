# Adopt tflint-ruleset-avm 1.0.0

**Status**: complete
**Started**: 2026-09-01
**Updated**: 2026-09-01
**Branch**: `jaredfholgate-adopt-tflint-avm-v1`

## Outcome

Adopt the breaking rule-name and native severity configuration contract from
[`Azure/tflint-ruleset-avm` 1.0.0](https://github.com/Azure/tflint-ruleset-avm/releases/tag/v1.0.0),
defined in [ruleset pull request #159](https://github.com/Azure/tflint-ruleset-avm/pull/159).
Pin the release, migrate every vendored AVM rule identity to its
canonical `avm_*` name, and replace module-side deferred-rule demotion with
plugin-provided `notice` severity while preserving inline, non-failing findings.

## Checklist

- [x] Pin the AVM TFLint plugin to 1.0.0 in the manifest and vendored configs.
- [x] Migrate every AVM plugin rule identity to the canonical v1 name.
- [x] Configure the currently deferred rules as native `notice` rules in HCL.
- [x] Remove module-side deferred-rule lists, predicates, tags, and demotion.
- [x] Preserve inline warnings for deferred and deprecated-interface notices.
- [x] Update fixtures, tests, documentation, changelog, and stale identities.
- [x] Prove parsed severity comes from TFLint output with no hard-coded list.
- [x] Run the full validation, including released-plugin attestation.

## Validation

- `./build.ps1 pre-commit`: passed.
  - Unit: 1,017 passed, 8 skipped.
  - Component: 29 passed.
  - Layout and lint passed; PSScriptAnalyzer recovered from its documented
    transient analyzer-engine race.
- `./build.ps1 integration`: passed, 21 passed and 3 fixture-specific skips.
- Released `tflint-ruleset-avm` 1.0.0 installed through `tflint --init` with
  artifact attestation and reported the canonical rule names.
- The direct TFLint JSON probe reported a native HCL `notice` as `info`; the
  module's rule-agnostic compatibility normalization returned it as `notice`
  without changing the default warning failure threshold.
- `git diff --check`: passed.

## Blockers or dependencies

None. The v1.0.0 release was published during this slice, so the previously
release-dependent installation and attestation checks were completed.
