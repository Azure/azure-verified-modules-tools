# Approved native Bicep route-table smoke

**Status**: blocked
**Started**: 2026-10-03
**Updated**: 2026-10-03
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Run the single approved route-table defaults case from the unchanged
registry snapshot in the explicitly approved disposable test subscription.
Use `eastus`, one validation attempt and one deployment submission,
followed by ordinary runner cleanup. Verify the temporary group is absent,
completed-state cleanup is a no-op and the exact root deployment history
record is separately removed. The reaper is not part of this test.

No other live case, existing management group, protected subscription,
tenant-wide setting, permission change, release or registry cutover is
authorized. Operational identifiers, state and detailed results stay in
private session evidence.

## Checklist

- [x] Recheck the original bounded approval and verify it has not been used.
- [x] Qualify the exact module bytes locally, as an extracted package and
      through all 17 hosted checks.
- [x] Bind the driver to that archive and the matching hosted receipt.
- [x] Complete the approved process-only Azure PowerShell sign-in.
- [ ] Rebind the smoke to the resource-group absence correction after its
      local, package and hosted qualification.
- [ ] Renew the ended PowerShell process sign-in once those bytes are ready.
- [ ] Run the one unchanged defaults case with ordinary cleanup.
- [ ] Verify resource absence, state-only no-op and exact history removal.
- [ ] Record the actual result without expanding the qualification claim.

## Validation

Qualified source: `d25c1fe93119b2afeb7038ce80e968a1b3d31f5e`.
Unsigned archive SHA-256:
`1DD4562705310CF5A2191638C917EE4B9FCE079053D6D1FD7AC7B90B185FF716`.
[Hosted checks](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37117924997)
all passed. The dependency-scope follow-up records the full package and
local evidence.

Registry snapshot: `89b1910d5d11e4f87579ae98e119effe9b7c9578`.
Case: `avm/res/network/route-table/tests/e2e/defaults/main.test.bicep`.
The driver verifies the immutable registry archive and all ten module files,
plus the qualified package and pinned compiler. No case-local assertion
suite or post hook exists; report them as `not-present`, not passed.

The first sign-in attempt failed because this host does not provide the
parent window handle required by Windows browser authentication. Inspection
confirmed that e2e was never invoked: no submission marker, no cleanup
state and no runner result exist. No deployment was attempted.

The user explicitly approved process-only device-code sign-in instead.
The private retry preserves the first result and requires matching target
and package evidence plus the absence of any prior invocation or cleanup
state. It uses a distinct attempt directory, which must not already exist.
It does not retry any deployment submission.

The device code expired before authentication completed. The second
attempt also has no invocation marker, cleanup state or runner result.
The approved validation and deployment budget remains unused. Both
authentication-only results are retained; do not generate repeated codes
until the user is ready to complete one.

The user has now confirmed readiness and requested a fresh code. The
authentication-only retry checks both retained results for no invocation
or cleanup state before continuing with the unchanged approval.

The background retry's sign-in prompt was not readable through the task
interface. That process was stopped, and its directory was checked again:
no invocation marker or cleanup state exists. A visible terminal with
readable output replaces that interaction path; the retained stop evidence
and marker checks prevent turning authentication recovery into a deployment
retry.

The readable captured prompt was delivered, but that sign-in was not
completed. On the subsequent user-requested attempt, PowerShell sign-in
succeeded and its process was retained while CLI prerequisites were checked.
The shared CLI cache held only a tenant-level entry. Its approved refresh
encountered a stale tenant's MFA requirement and was stopped without
changing security settings. The user confirmed the intended tenant, and
a clean temporary CLI profile was signed into only that tenant.

Both sign-ins and the paired identity check then succeeded. The new-group
preflight failed on the SDK's unclassified missing-resource-group exception.
The result again confirms no e2e invocation or submission. The shared
[resource-group absence correction](2026-10-03-bicep-resource-group-absence.md)
must be qualified before continuing; this is not an Azure deployment
failure or a request for broader permissions.

The corrected package and ordinary full local gate now pass. Its hosted
qualification remains pending; the earlier receipt cannot qualify the new
bytes. The isolated CLI descriptor still confirms the intended enabled
test subscription without another sign-in or a shared-cache refresh.
The successful process-only PowerShell session ended with the preflight
failure and must be renewed after the correction is ready.

## Blockers or dependencies

Waiting for hosted qualification of the shared SDK absence-handling correction.
No test resources were created and no resource cleanup is required for
the setup attempts. One passing route-table case
would not qualify every cleanup provider, higher-scope permission,
managed-identity representation or failure/recovery path. Other live
coverage and rollout decisions require separate approval.
