# Example-repo TME state canary

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Copy only `avm-ptn-example-repo.tfstate` from the original state account to
`stavmstate92172623a0c0c6/tfstate`, then run the repository-sync workflow from
this branch with `plan_only=true` and project synchronization disabled.

The user authorized this copy, branch test, and any required permissions.
Source state and all other repository state blobs remain untouched. This is
not the final cutover and does not authorize Terraform apply.

## Checklist

- [x] Verify the source subscription, blob access, branch, and backend inputs.
- [x] Add temporary Blob Data Contributor for the operator at the TME container.
- [x] Conditionally download the unlocked source and upload without overwriting.
- [x] Verify hashes and lineage/serial; remove local state copies.
- [x] Remove the temporary operator role without altering runtime UAMI access.
- [x] Dispatch the exact branch for a single plan-only example-repo canary.
- [x] Record the run result, limits, and any remaining blocker.

## Validation

- Copied 299,393 bytes at 2026-09-09 11:25 UTC. SHA-256:
  `C747F32780B86C848F8DB13024A31F2251A9E1CE088F536CA505E38B1A1072D8`.
- Lineage `f40f5399-e049-ef53-354e-e2fe1d230371`, serial `760`, 29 state
  resources. TME readback matches; source ETag was unchanged across the copy.
  Temporary local state files were removed.
- Temporary operator role `2d417c1c-d44a-4a55-a934-9bf9db6f4886` was removed.
  The user explicitly approved briefly removing and restoring the storage
  deletion lock to permit cleanup. Original lock settings and runtime UAMI
  access were verified afterward.
- [Branch canary run 34345756714](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34345756714)
  succeeded at commit `d3663ecc62c6b5fbc5ebf3a6b29cc97c6f0ae046`.
  Matrix contained only `avm-ptn-example-repo`; `plan_only=true`,
  `force_file_update=false`, and `sync_project_items=false`.
- Logs confirm OIDC login to TME, initialization against the copied TME blob,
  Terraform plan, and no apply. The plan proposed four additions (the Copilot
  environment and its three identity secrets), zero changes, zero destroys.
  No Azure identities or other resources were proposed for recreation.
- The authoring pre-commit stage produced no changes. Three unrelated tooling
  repositories emitted discovery naming annotations; the following slice
  adds them to the built-in exclusion list.

## Blockers or dependencies

A copied state can become stale if the original workflow writes again.
Re-copy current state under a full writer freeze before the eventual cutover;
never apply independently from both copies.
