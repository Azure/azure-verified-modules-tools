# Hosted native Bicep qualification

**Status**: complete
**Started**: 2026-10-03
**Updated**: 2026-10-03
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Resolve the hosted qualification failures after the native package slice
without changing coverage floors, lint rules or deployment behavior. Prepare
live qualification for the existing BAMI test tenant; target selection is
not approval to create or delete Azure resources.

## Checklist

- [x] Read the exact hosted results for `0a109ad`.
- [x] Make deferred location-token filtering visible to static analysis and
      preserve strict handling of every other unresolved token.
- [x] Inspect the Windows timeout and apply the user-approved 25-minute
      test-job ceiling without suppressing tests.
- [x] Run focused controls, requalify the changed package and pass the
      ordinary development gate.
- [x] Finish the local correction and prepare the owned commit.
- [x] Verify hosted results for the corrected commit.
- [x] Resolve the existing test-tenant configuration without selecting a
      production subscription or changing Azure context.
- [x] Obtain approval for one bounded route-table smoke and its setup,
      conditional on passing local and hosted checks.

## Validation

The [hosted run for `0a109ad`](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37056322203)
passed the Ubuntu and macOS test jobs, all six Terraform integration jobs,
and workflow tests. Ubuntu coverage is 71.37%; Windows coverage is 71.33%,
both above the unchanged 70% floor. Windows then reached the job's
15-minute limit during component execution; its component result is
incomplete, not a pass.

Hosted lint reported `PSReviewUnusedParameter` for `DeferResourceLocation`
in `Resolve-AvmBicepTestToken.ps1`. The switch is referenced only inside a
pipeline filter. The conditional now runs outside that callback with the
same token-selection behavior. Standard lint and 24 focused token/input
controls passed, including six new strict-deferral cases.

The retained Windows results contain passing unit/coverage results and
three completed component groups with no failures. The missing group
includes the existing module-catalog suite, which dominates the matching
completed Ubuntu group's runtime. The user approved increasing the matrix
test-job ceiling from 15 to 25 minutes. Per-test timeouts, selected suites,
coverage settings and the separate lint/integration jobs are unchanged.

The refreshed unsigned 0.0.0 archive has SHA-256
`EEB2E84B33D23B6F57B33EE4FBBA0A98F281BD60AE0FD9D8D9191B805C621D83`.
Its source boundary is `0a109ad7faab81a938c6a33380246fc4e420c5ab` plus only
the token-filter correction. All 348 payload files were byte-verified and
56 command definitions resolved inside the fresh extracted module.
Packaged tests passed 168 unit and 143 component controls, five real
scaffold compiles and six real-compiler registry scenarios with simulated
Azure. All 5,611 registry snapshot files remained unchanged.

The final ordinary `build.ps1 pre-commit` passed layout, lint, 2,813 unit
tests and 1,257 component tests, with nine unit skips and one component
skip. The component tier used four child processes. The complete local gate
took 15 minutes 10 seconds; this is not a prediction of hosted runtime.
The workflow regression verifies the approved 25-minute test-job ceiling.

All 17 hosted checks for `9234c88bb7c021ad17ac0976fa32f1bbda439eb6`
passed in the
[corrected run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37114687302):
lint, CodeQL, all three complete test jobs, workflow tests, six integration
jobs and reporting. The Windows job finished in 13 minutes 31 seconds.
The approved live setup then exposed a separate
[native dependency import-scope issue](2026-10-03-bicep-azure-dependency-scope.md)
before sign-in or deployment.

The user's existing-tenant selection resolves to the configured BAMI tenant,
the 28-subscription test pool and management group `avm-test`. Tenant-scoped
subscription discovery confirms the selected test subscription is enabled.
Admin and Persistent remain excluded. No sign-in, context change, resource
deployment/deletion or permission change has been performed.

## Blockers or dependencies

The current local CLI context belongs to a different tenant. Live execution
must use an explicitly verified test-tenant context, not the ambient default.
Az.Subscription 0.12.0 was subsequently installed in the approved
CurrentUser scope without changing its satisfied Accounts dependency.
Azure PowerShell has no saved test-tenant context. The separately tracked
import-scope correction passes the real local dependency check, refreshed
package qualification and ordinary full local gate. Its own hosted
qualification is still required before sign-in.

The user approved one unchanged registry route-table defaults case in the
existing BAMI test pool's first subscription, fixed to `eastus`, with one
submission and removal of its temporary group, route table and deployment
records. The approval includes installing only the missing Az.Subscription
0.12.0 module in CurrentUser scope and a process-only interactive sign-in
completed by the user. Setup and live execution must wait for both the local
and hosted checks to pass. No other live case, protected scope, release or
registry cutover is authorized.
