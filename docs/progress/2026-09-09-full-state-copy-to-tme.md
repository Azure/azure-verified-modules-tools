# Full state copy to TME

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-tme-migration-receipt`

## Outcome

The user disabled the workflow and authorized copying all current repository
state files to TME while they arranged the merge. The copy is complete: source
`stoe2etestingmodulestate/tfstate` remains intact and destination
`stavmstate92172623a0c0c6/tfstate` is ready. The workflow remains disabled.
No Terraform apply or workflow enablement was authorized or performed.

Documentation handoff: `jaredfholgate-terraform-state-migration` explicitly
transferred this completed migration receipt to `jaredfholgate-tme-migration-receipt`
after [#103](https://github.com/Azure/azure-verified-modules-tools/pull/103)
merged at 2026-09-09T12:08:15Z while the copy was running. This follow-up is
documentation-only, based on the merged `main`.

## Checklist

- [x] Confirm workflow disabled manually and no active/queued sync runs.
- [x] Inventory 266 unlocked source state blobs.
- [x] Obtain temporary container-scoped access for the operator.
- [x] Copy missing blobs and reconcile the existing example-repo snapshot.
- [x] Verify all SHA-256 hashes, lineage/serial values, and final inventories.
- [x] Remove raw local state copies and temporary permissions; retain the lock.
- [x] Record the migration receipt for the user's merge handoff.
- [x] Document the Windows case-collision guard and parse the README snippets without execution.

## Validation

- Documentation follow-up: all seven README PowerShell snippets parsed without
  execution. The doc-only gate skips tests; no copy or runtime operations were
  repeated.
- Verified at 2026-09-09 12:22:07 UTC: all 266 current state blobs, totaling
  69,518,042 bytes, match in TME. Added 265 missing blobs; the example-repo
  state was already byte-identical and was not rewritten. No refresh was needed.
- Every destination SHA-256, lineage, and serial matches its source. Source
  ETags, byte counts, names, and unlocked lease status were unchanged across
  the copy. Final destination ETags were unchanged during readback.
- Preserved both case-distinct Red Hat OpenShift state blob names. Used
  case-safe local filenames and exact remote names rather than a Windows
  batch download that would collide. Transfers used Entra bearer authentication,
  conditional source reads, and create-only destination writes.
- Non-secret manifest and receipt retained in session artifacts, not in Git.
  Manifest SHA-256:
  `9DD6005417B1338E6C475AAAC4F0F90F7058248BAE354167F1295F2E365528DF`.
- All temporary raw-state files were removed. Temporary operator role
  `cc8eb3c2-be2f-40c9-bc7a-48318511c07a` was deleted using the approved
  lock-removal/restoration procedure. The original CanNotDelete lock and
  runtime UAMI's container-only access were verified afterward.
- Workflow remains `disabled_manually`, with no active or queued sync runs.
  No source blobs, old versions, GitHub variables, or runtime identities were
  changed. The copying operator performed no merge, workflow enablement, or
  Terraform apply.

## Blockers or dependencies

Source remains authoritative until cutover. The reviewed migration change is
merged, but workflow enablement and any Terraform apply still require explicit
user approval. The target has a verified complete copy ready for that handoff.
Historical blob versions/snapshots remain in the source account; do not remove it.
