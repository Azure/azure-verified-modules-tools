# Native Bicep execution inputs and cleanup recovery

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Prepare native validation and deployment with typed inputs, bounded retries,
same-process assertions and hooks, and `avm test cleanup` recovery. The
ordinary e2e engine remains unchanged in this slice; runner integration
continues in its own progress file.

## Checklist

- [x] Preserve authored keys/count names and typed CI input precedence.
- [x] Select generic subscription pools and supported resource regions.
- [x] Retain secure parameter overrides in memory.
- [x] Record each deployment attempt before submission and never resubmit
      an unknown outcome.
- [x] Defer cleanup while attempted deployment outcomes remain unconfirmed.
- [x] Export a cleanup-resume command requiring an explicit subscription
      and tenant.
- [x] Preserve same-process script state and shared Pester summary checks.
- [x] Run the ordinary full gate and commit/push.

## Validation

Focused controls pass: 42 workflow-input unit controls, 22 native/recovery
unit controls, three authored-name component controls, 32 cleanup-state
component controls, and 22 native/Pester component controls. The latter
includes real same-process Pester inside a separate test harness, not a
nested Pester invocation in the development test host.

Failed Pester assertions update LASTEXITCODE as well as the returned summary;
the native suite consumes its validated summary rather than treating that
exit code as a broken runner. Post hooks still check their exit code.
Existing, empty and absent environment variables, location, exit status and
cancellation are covered.

Offline reflection against installed Az.Resources 9.0.3 exercised its actual
ParameterUtility conversion: ordinary objects containing `reference` remain
values, ARM vault references remain references, secure strings stay secure,
and authored keys/count retain their values. No Azure command was invoked.
Layout and lint pass without rule or retry changes.

The ordinary full `.\build.ps1 pre-commit` gate passed: 2,710 unit controls
(nine skipped), 1,315 component controls (one skipped), no lint findings.
The gate finished in 15 minutes with expected negative-path test warnings.

## Blockers or dependencies

Main-runner wiring, hosted completion, provider-container expansion and
unmodified-registry qualification remain in the runner-integration slice.
No live Azure operations, dependency installation, authentication, release
or registry cutover were performed or authorized.
