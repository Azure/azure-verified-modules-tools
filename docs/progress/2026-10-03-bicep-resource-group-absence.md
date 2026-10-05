# Native resource-group absence verification

**Status**: complete
**Started**: 2026-10-03
**Updated**: 2026-10-03
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Handle the installed Azure PowerShell SDK's unclassified error for a
nonexistent named resource group without interpreting error-message text
or treating authorization failures as absence. Confirm that narrow case
with an exact ARM GET in the current validated subscription and require
HTTP 404 with `ResourceGroupNotFound`.

The shared lookup also serves resource-group-scoped execution, ownership
rechecks and cleanup recovery. Fix that common path rather than only the
private live-test driver.

## Checklist

- [x] Confirm both tenant-specific sign-ins succeeded.
- [x] Confirm the approved case stopped before e2e invocation or submission.
- [x] Trace the shared lookup and verify the exact ARM missing-group response.
- [x] Add strict unit controls and realistic missing-group component fixtures.
- [x] Correct only unclassified named-group lookup failure handling.
- [x] Requalify the unsigned package.
- [x] Pass the ordinary full development gate.
- [x] Commit, push and confirm hosted checks for the correction.

## Validation

The qualified `d25c1fe` archive reached the live preflight, but
`Get-AzResourceGroup` raised a plain `System.Exception` without an HTTP
status for the intentionally new group. The retained result has no e2e
invocation marker, no cleanup state and no runner result.

A separate, approved read-only GET of that exact group through the isolated
test-tenant CLI profile returned HTTP Not Found with the structured
`ResourceGroupNotFound` code. No resources were created.

Installed Az.Resources 9.0.3 has no `Test-AzResourceGroup` command, and its
`Invoke-AzRestMethod` does not accept HEAD. Use its supported GET operation;
do not add a nonexistent dependency or infer absence from localized text.

The new regression failed on unchanged runtime code. After the correction,
45 focused unit controls and 21 native workflow component controls pass,
including new-group creation and state-only recovery after an owned group
has already disappeared. The 40-case absence suite is included in
extracted-package qualification.

The verification applies only to a plain exception without an inner
exception, without an HTTP status, from a single-name group query.
Successful native results remain unchanged. Typed authorization, timeout,
transport and cancellation errors do not cause another request. Invalid
context identifiers and child-resource/query-shaped names are rejected.
Only a structured `ResourceGroupNotFound` under HTTP 404 confirms absence;
other, malformed and authorization-shaped responses remain failures.
Explicit error categories for authorization, connection, timeout and
invalid input also retain failure. `OperationStopped` alone is not treated
as cancellation because PowerShell also uses it for an ordinary thrown
exception; actual cancellation types remain excluded.

The initial combined focused invocation hit the analyzer's existing
`NullReferenceException` failure. Isolating the changed file exposed one
indentation finding, corrected with the repository formatter. The next
standard lint run passed. No lint rules or retry policy changed.

The refreshed unsigned 0.0.0 archive has SHA-256
`39B1694118A83A89F34295487D2290ED3C500A9D68B028468C4094BBBA004843`.
Its source boundary is `45ca5c27761484686baea7ac7023f1cc49c9270f` plus
only the shared lookup correction, whose SHA-256 is
`4FF367EC5B084895D5EC051F893628B6B494A93287D8FB3023372ACC865547CD`.
All 348 payload files were byte-verified and 56 command definitions resolved
inside the extracted package. Packaged tests passed 214 unit and
146 component controls, five real scaffold compiles and six real-compiler
registry scenarios with simulated Azure. All 5,611 registry files remained
unchanged.

The initial full development gate was interrupted during unit execution
after layout and lint passed; its log has no final result, and no build
process remained. The ordinary gate was then rerun without rebuilding or
replacing the qualified archive. Layout and lint passed; 2,854 unit tests
passed with nine skips, and 1,260 component tests passed with one skip.
The six component reports contain no failures. The gate completed in
17 minutes 13 seconds; expected negative-fixture warnings remain visible.
All 348 source files still match the qualified package.

The correction was committed and pushed as
`7ef4f14f964d1713941146786fc1abfb4b70f1cc`. All 17 checks passed in its
[hosted run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37132153429);
the Windows test job completed in 14 minutes 19 seconds.

The [approved live route-table smoke](2026-10-03-bicep-live-route-table.md)
then passed against those exact package bytes. The previously failing
native preflight and post-cleanup group-absence lookup both succeeded.
The single recorded deployment completed successfully, normal cleanup
finished, completed-state recovery was a no-op and the exact root history
record was separately removed.

## Blockers or dependencies

No blocker remains for this correction. The original one-case budget was
consumed successfully; it does not authorize another deployment.
Qualification beyond the bounded route-table case, permission changes,
release and registry cutover remain separate approval gates.
