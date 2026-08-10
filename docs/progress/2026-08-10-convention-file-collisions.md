# Convention file collision reconciliation

**Status**: complete
**Started**: 2026-08-10
**Updated**: 2026-08-10
**Branch**: `jaredfholgate-fix-convention-file-collisions`

## Outcome

`FileMustNotExist` rename fixes now reconcile existing destination files.
Meaningful source content is appended with a safe line boundary before the
source is removed, while whitespace-only sources are removed without changing
the destination. The shared behavior covers `output.tf`, `variable.tf`, and
equivalent repository-local rules.

## Checklist

- [x] Merge meaningful source content into an existing destination.
- [x] Remove whitespace-only source files without rewriting the destination.
- [x] Preserve failures for non-file and same-path destinations.
- [x] Add primitive-level regression coverage for each collision shape.
- [x] Document the behavior in the changelog and Terraform migration guidance.
- [x] Reproduce the reported collision against the affected module.
- [x] Adopt the per-slice progress structure from `main`.

## Validation

- `./build.ps1 pre-commit` passed with five tasks and zero errors.
- The reported two-byte CRLF-only `output.tf` was removed while the existing
  `outputs.tf` remained byte-for-byte unchanged.

## Blockers or dependencies

None.
