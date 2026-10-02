# Bicep PSRule policy evaluation

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Run the registry's required and advisory PSRule baselines against the selected,
tokenized Bicep e2e sources and their referenced files in `avm check policy`
and `avm pr-check`, with inspectable, file-specific diagnostics. Do not change
registry CI, invoke Azure, or claim parity for checks that have not run.

## Checklist

- [x] Trace the pinned registry selection, token-replacement, rule, suppression,
      and result contracts and choose a deterministic local policy source.
- [x] Evaluate required and advisory baselines on every applicable e2e source
      without modifying module files; fail closed on missing input or results.
- [x] Add positive and negative unit/component fixtures and independent review.
- [x] Run `./build.ps1 pre-commit`, record the resulting coverage, commit, push,
      and update the existing review.

## Validation

The pinned registry uses `defaults` and `waf-aligned` `main.test.bicep`
sources, the repository's
`utilities/pipelines/staticValidation/psrule/ps-rule.yaml` and `.ps-rule/`
settings and suppressions, required `Azure.Pillar.Reliability` and
`CB.AVM.WAF.Security`, and advisory `Azure.Default` and
`Azure.Pillar.Security`. Bicep checks lazily import PSRule 2.9.0 and
PSRule.Rules.Azure 1.47.0; Terraform import and routing do not require them.
Missing versions produce an install instruction rather than silently
auto-installing modules. The pinned Bicep CLI performs file expansion.

Each selected test and recursively referenced local module, import, file
load, and Bicep config is copied to a uniquely created temporary directory.
Only the staged copy receives required token replacements. Unset,
unrecognized, or credential-like tokens and missing or linked references
fail before evaluation. Each baseline must exist, contain rules, and return
records attributed to its selected test with known rule names and expanded
Azure resource targets. Empty, malformed, non-expanded, and failed
evaluations fail closed; only advisory rule violations are warnings.

Focused `./build.ps1 pre-commit -TestName 'Bicep PSRule*','Invoke-AvmCheckPolicy*','Bicep static convention checks*'`
passed layout, lint, 13 unit and 45 component tests before review.
Local-only smoke using the complete pinned registry PSRule configuration,
its seven suppressions, its custom WAF baseline, and pinned Bicep 0.47.16
executed all four baselines over two staged tests (eight inspectable
evaluations). As expected, the deliberately noncompliant storage fixture
reported 12 required-rule errors and 23 advisory warnings; no live Azure
or MCR request was made.

Independent code review identified a text-loaded script whose tokens would
otherwise remain unchanged and CRLF in new source files. Source collection
now tokenizes all text references regardless of extension, preserves
`loadFileAsBase64()` byte loads, and tests both cases. All new source files
were normalized to LF/UTF-8 without BOM.

The final unfiltered `./build.ps1 pre-commit` passed layout, lint, 1,924
unit tests (nine skipped), and 959 component tests (none skipped); 49
warnings came from existing exercised negative-path tests. The separate
local-only smoke with the full pinned registry configuration executed all
eight test/baseline combinations with no uninspectable results. The policy
step no longer reports `psrule-incomplete`; missing dependencies, settings,
sources, or results produce specific failing issues. Convention still
reports its independently tracked gaps, so a partial `avm pr-check` cannot
be mistaken for complete Bicep CI parity.

## Blockers or dependencies

Publication-aware convention rules and child artifact drift are separate
slices. Both existing telemetry source forms must remain valid throughout
any later literal-parity review. For publication history the
authoritative online check must read MCR tags; unavailable or offline
responses cannot be treated as published. Existing registry CI remains in
place. No registry CI change, release, merge, or live Azure/MCR call is made
in this slice.
