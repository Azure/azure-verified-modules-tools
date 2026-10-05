# Final native convention families

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Migrate layout and publication requirements, then remove the final family
wrapper and its Findings/Crashes protocol. Preparation failures remain ordinary
compiler/filesystem/Git/network diagnostics; authoring assertions are native.

## Checklist

- [x] Native layout, test-folder and ignore-file requirements.
- [x] Native publication/changelog/ancestor-version requirements.
- [x] Remove the final ordinary checkers and generic family wrapper.
- [x] Native execution counts, negative controls and strict completeness.
- [x] Pester 5/6 qualification and full local gate.
- [x] Preserve qualified changes locally under the authorization hold.

## Requirement map

Reference: `Azure/bicep-registry-modules@ca00e89a931f637f628503a3a625e7d487157496`.
Assertions now live in `Resources/bicep/conventions/Layout.Tests.ps1` and
`Publication.Tests.ps1`; their input helpers only enumerate files or reuse
prepared version/history data.

| Previous requirement | Native requirements and evidence |
| --- | --- |
| `module.tests.ps1:73-375`: source, compiled JSON, README and resource folder names | Independent file/name cases; root and child positive execution, missing and mis-cased file controls, child plural/double-hyphen positives and uppercase/underscore negatives |
| Single-scope version; multi-scope parent and tests | Independent version, tests/e2e directory, WAF and per-scope tests; existing multi-scope/defaults exemptions retained, directory casing and missing required-test negatives |
| Deployment test folders and `.e2eignore` | Independent non-link, source file, ignore-file, allowed exclusion, readability and reason cases; malformed UTF-8, wrong casing, empty reason and required-test exclusion controls |
| `module.tests.ps1:1666-1989`: published or next-target changelog sections | Independent changelog readability, per-release membership and required target section; four native positive cases plus unknown release, missing target and unreadable changelog negatives |
| `module.tests.ps1:1990-2055`: versioned ancestors after child major/minor changes | Independent parent history and version increment/reset cases; existing child/ancestor publication mutations retained |
| Full family execution | Native registration counters replace Findings/Crashes; missing registration, failed containers, skipped checks and missing publication input cannot pass |

The root/child layout fixture declares 22 native requirements: 18 for the root
(including the existing max-test exclusion) and four for the child. The
upstream "Top-level defaults" title actually filters multi-scope parents;
this migration preserves that behavior instead of inventing a new requirement.

Git/MCR failures remain explicit preparation diagnostics. The package does not
download registry scripts, and publication preparation still requires trusted
history rather than treating unavailable history as successful validation.

## Validation

Implementation is qualified. Initial controls exposed a nested test-helper
scope mistake, an incorrect expected count that omitted three existing ignore
checks, and a Windows casing test that overwrote rather than renamed a file.
Those test setup errors are corrected; strict lint findings were also fixed.

- Pester 6.2.0: `.\build.ps1 pre-commit` passed layout, lint, units and
  1,551 component cases (one existing skip), with no failures.
- Pester 5.7.1: `.\build.ps1 test,component -TestName
  'Invoke-AvmBicepConventionSuite*','Get-AvmBicepChildPublishAllowlist*',
  'Bicep static convention checks*'` passed; 148 component cases and one
  existing skip.
- Native-only positives execute exactly 22 layout and four publication cases.
- Source/test search found no remaining checker or rule-importer references;
  the only legacy wrapper-name reference is a negative runner assertion.
- The 8m44.9s full-gate duration uses a changed test set and is not a
  performance comparison.

## Blocker

Publication remains on hold. No authentication change, alternate publishing
route, release or registry cutover is authorized.
