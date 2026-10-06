# Default packaged Bicep compliance

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Replace the default registry compliance dependency with one packaged native
Pester run for conventions, metadata and README requirements. Keep authored
unit tests isolated in a child process, preserve explicit compliance overrides
and filters, and qualify a utility-free consuming repository.

## Checklist

- [x] Reuse batched preparation without nested validation runs.
- [x] Wire default compliance and preserve overrides, recursion and filters.
- [x] Reject incomplete execution and preserve issue codes/severities.
- [x] Component and built-package acceptance with positive/negative evidence.
- [x] Pester 5/6 qualification and full local gate.
- [x] Commit locally; retain the publication hold.
- [x] Remove the remaining publication-history tracking-ref prerequisite.

## Validation and remaining boundary

The Pester 5 full gate passed: 1,563 component tests passed, one existing skip,
with layout, lint and units green (10m13.5s; not a performance comparison).
Pester 6 focused routing passed 200 component tests with one existing skip.
Pester 6 built-package acceptance passed all seven selected cases: native
compliance plus an authored child-process test, four metadata/telemetry/README
negative cases, real PSRule execution of eight baselines across two examples,
and rejection of insecure storage. The positive fixture uses a nullable tags
UDT rather than an untyped object; the latter correctly produced an advisory.

Compliance preparation is batched; actual requirements run in one packaged
Pester invocation. Module-authored tests stay isolated. Explicit alternate
suites, recursive scopes, filters and no-match skipped status are covered.
Native warning assertions remain visible in RunsFailed without turning an
advisory into a fatal validation error; authored test failures are always fatal.

The acceptance consumer has no registry utilities or Git checkout, but publication
Git-state/target preparation and external API/MCR catalogs are simulated.
The final dependency audit identified that real publication preparation still
requires a trusted registry tracking ref. This must be removed before claiming
complete independent-consumer acceptance or setting the capability marker.
The [checkout-free publication slice](2026-10-06-checkout-free-publication-data.md)
subsequently removes this prerequisite and tests real publication preparation.
No validation scripts or common defaults are read from the registry.
No release, cloud action, authentication change or push was performed.
