# Telemetry mock dependency safety

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Preserve authored random-provider mocks when dependency use cannot be ruled
out locally. Keep automatic cleanup for the standard Key Vault migration.

## Checklist

- [x] Cover JSON configurations, remote or unscanned local modules, and
      explicit test provider mappings.
- [x] Keep known local-module cleanup working without installing providers
      or making cloud calls.
- [x] Run focused tests, the full local gate, and commit and push.

## Validation

The [Key Vault plan-only confirmation](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36983140005)
passed against the preceding central fix at `b4fd7d3`, with publication
skipped. This slice adds dependency-safety coverage before
any broader migration; it does not authorize module publication or Azure
deployment.

Six focused regression cases failed before the guard: root and test-setup
JSON configurations, three unscanned module sources, and an explicit
provider mapping. Known local-module cleanup already passed.
The first focused post-fix run passed all 42 transform tests.
All 21 real-MaPoTF telemetry integration cases subsequently passed with
zero skips, including provider-mocked fixture suites and no-destroy local
state migration. The full pre-commit gate passed layout, lint, 2,606 unit
tests (9 existing skips), and 1,287 component tests (1 existing skip).

## Blockers or dependencies

Do not infer that an unscanned dependency has no random-provider use.
Retain its mock rather than changing the authored test behavior.
