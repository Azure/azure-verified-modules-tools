# Bicep compiled static checks

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

The Bicep convention engine now compiles root, child, and e2e sources with the
pinned CLI. It evaluates compiled module schema, metadata, parameter/UDT,
variable, output, and telemetry rules, including legacy resource arrays and
symbolic ARM 2.0 resource objects. E2e source requirements now depend on the
compiled resource count. No module files, metadata rules, Terraform paths, or
registry workflows are changed by the check.

The [per-assertion ledger](2026-09-30-bicep-static-checks-parity.md) is
cumulative across both slices. Assertions and behavior added in this slice:

| Pinned registry source | Enforced convention behavior |
| --- | --- |
| M:48-60,786-846 | Compile every discovered module/e2e source; validate ARM shape, one of four current scope schemas, HTTPS, source metadata name/description |
| M:858-1176 | Resource-group location default; conditional/versioned telemetry parameter (with scaffold description alternative); flattened nested parameter/UDT names, descriptions, requiredness and typed-object schemas; six known interface UDT references, nullable tags and principal-ID output |
| M:1192-1383, D:75 | Variable naming; telemetry deployment, condition, nested output, source-loaded prefix and JSON agreement (including compiler alias and scaffold declaration alternative); child-module telemetry variable and forwarding by family/scope |
| M:1417-1636 | Output naming, descriptions, resource-group, primary resource and principal-ID outputs; UDT array, nullability and naming guards |
| M:2150,2220,2235,2252 | Gate deploying-test source rules on compiled e2e resources, not a source-line guess |

M:1008 remains **advisory** for absent/pre-1.0 version files and becomes a
required error from version 1.0. The location-output check uses the README's
primary ARM resource type, including symbolic resources, rather than the
registry test's nonmatching module-folder path that silently missed many
resources. A bad source, malformed compiled JSON, unavailable compiler,
invalid metadata prefix, or broken definition produces a named diagnostic;
it is not a skipped check. The existing `avm transform` checks checked-in
`main.json` drift for ordinary scopes, but does not discover children under
`modules/`. This slice compiles those children, but cannot claim their stored
artifacts are current. It accepts the shipped scaffold's exact alternate
telemetry declaration and description while still checking its compiled
prefix and deployment. The pinned registry checks only its different literal
declaration and description, so literal parity is deliberately partial.

`avm.bicep.convention-incomplete` continues to fail on six missing groups.
`avm.bicep.psrule-incomplete` continues to fail separately with
`ToolSource='not-run'` for required and advisory PSRule baselines.

## Remaining static gaps

- M:131 and M:157: publication allowlist and resource-folder singularization.
- M:415-585 and M:2062: module workflow/dispatch/path-filter and CODEOWNERS
  rules; preserve upstream/fork-safe gates during any migration.
- M:651 and M:2385: README regeneration equivalence and advisory API-version
  checks.
- M:717 and D:75: checked-in `main.json` drift for children under `modules/`
  is not checked by transform; freshly compiled convention checks still run.
- M:872, M:1240 and M:1313: reconcile the scaffold telemetry description,
  variable and selector with the registry's literal legacy checks. Both exact
  forms are checked here; they are not identical to registry acceptance.
- M:1722, M:1928 and M:2022: publication-aware next-version changelog,
  published/pending version set, and parent/child increment rules.
- W:63/65 and W:93/95: PSRule evaluation against tokenized defaults and
  waf-aligned sources plus referenced files, suppressions, and required vs
  advisory baselines. **PSRule has not run.**
- Module-owned `tests/unit` and the independent metadata/source rules remain
  on their separate review branches; no registry CI cutover is authorized.

## Checklist

- [x] Map every compiled registry assertion to a first-party rule, an existing
      equivalent, or an explicit remaining gap.
- [x] Compile root, child, and e2e Bicep sources safely with the pinned tool
      and validate their compiled templates.
- [x] Enforce compiled schema, parameter, UDT, output, and telemetry rules with
      actionable diagnostics on root and child scopes.
- [x] Add passing and failing unit/component fixtures, including malformed
      compilation and required-check failures.
- [x] Complete an independent review and address findings.
- [x] Run the full `./build.ps1 pre-commit` gate after all code and test edits.
- [x] Update the pinned coverage ledger and existing review, then commit and
      push this standalone slice.

## Validation

Local fixture sources compiled with pinned Bicep CLI without Azure or network
calls; component tests consume those generated ARM fixtures through a mocked
pinned compiler. The shipped scaffold also compiled locally with Bicep
0.47.16: its `avmTelemetryIdPrefix` variable aliases `$fxv#0` and its compiled
deployment name references that variable. Focused `./build.ps1 test -TestName
'Compiled Bicep convention rules*'` passed 11 unit tests. Focused
`./build.ps1 component -TestName 'Bicep static convention checks*'` passed 29
component tests, including all five module/e2e source compilations and
root/child negative diagnostics. `./build.ps1 layout`, `./build.ps1 lint`,
and `git diff --check` passed. Changed source files have LF and no UTF-8 BOM.
The final unfiltered `./build.ps1 pre-commit` gate passed layout, lint,
1,915 unit tests (nine skipped), and 940 component tests (none skipped).
Its 49 warnings came from exercised negative-path tests.

Independent review identified two false outcomes. The shipped scaffold's
telemetry source variable, JSON selector, and parameter description differ
from the registry's literal checks; this slice accepts the two exact forms,
tests the scaffold form, and records literal parity as partial. An underscored
UDT name previously passed the new camelCase rule; the regex now rejects it
and a unit test covers it. Inspection also found that the existing transform
excludes `modules/` children from stored `main.json` drift checks, so the
ledger and fail-closed coverage list state that gap rather than claiming
all child artifacts are checked.

## Blockers or dependencies

The Bicep metadata/source and test-tier changes are on separate branches.
Actual PSRule evaluation, publication-aware governance, and registry CI
migration remain outside this compiled-convention slice. No Azure or
production operations are authorized.
