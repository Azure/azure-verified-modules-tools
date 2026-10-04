# Repository sync provider evidence

**Status**: complete
**Started**: 2026-10-04
**Updated**: 2026-10-04
**Branch**: `jaredfholgate-repository-sync-evidence-fix`

## Outcome

Correct the BAMI provider-evidence rejection in the cancelled
[repository sync run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37221891707).
The new branch starts at main `b9162f2a8a5c80d0b75da3f1a5cf557088ec09a8`.
Completed Terraform data-source reads are in the saved plan's refreshed
`prior_state.values.root_module`, not `planned_values.root_module`. The guard
searched only planned values and therefore could not find either provider's
context or configured group lookups.

Read those completed observations from the same saved plan, rejecting any
pending reread instead of accepting stale evidence. Keep managed-resource
validation on planned values and preserve every tenant, controller, subscription,
principal, group, federation and Owner-removal check. The allow-listed group
summary uses the refreshed observations and their sensitive-value masks.

## Checklist

- [x] Read repository guidance and confirm the merged baseline and open reviews.
- [x] Reproduce the actual evidence shape without live tenant or state access.
- [x] Correct production code and cover valid and invalid identity evidence.
- [x] Run focused checks and the full local gate.
- [x] Prepare the validated correction for publication on the new feature branch.

## Validation

The cancelled run has no uploaded artifacts; its job log confirms the exception
at `TestTenant.ps1:208` but contains no raw plan or provider observations.
A native `terraform plan` / `show -json` test with only built-in providers and a
disposable local-backend fixture independently confirms that completed data
reads appear in refreshed prior state and are absent from planned values and
resource changes. The production reader consumes that native JSON directly.

Moving the existing BAMI fixture to this native shape made its positive guard
test fail with the exact production exception before the code fix. The previous
mocked-provider gate passed because its adapter injected observed data into
planned values; the adapter now models the correct snapshot location instead.
Its evidence still comes from the actual Terraform `test_group_contract`
output, not configured expected identifiers or shared group contents.

Validation results:

- Focused `.\build.ps1 pre-commit` for candidate safety, orchestration and summaries:
  44 unit and 49 component tests passed before the final sensitive-group control.
- `.\build.ps1 integration -TestName 'Integration: Terraform plan data evidence*'`:
  two native local-backend controls.
- `.\build.ps1 test-tenant-terraform`: 31 mocked-provider Terraform tests,
  including the actual candidate plan guard.
- Full `.\build.ps1 pre-commit`: layout and lint passed; 2,887 unit and
  1,278 component tests passed, with nine unit skips and one component skip.
  No failures; the gate reported 82 test-path warnings.

New controls cover missing or malformed snapshots, absent or duplicate provider
evidence, wrong provider identity and group bindings, pending data reads,
historical managed resources, and sensitive fields in refreshed group summaries.
Raw downloaded logs and local diagnostic files stay outside the repository.

## Blockers or dependencies

No local implementation blocker remains. No live Azure, Graph, Entra, backend
or state operations are authorized. Do not
dispatch, retry or resume repository sync, repair state, change permissions or
merge the correction.
