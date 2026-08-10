# E2E location retry

**Status**: complete
**Started**: 2026-08-10
**Updated**: 2026-08-10
**Completed**: 2026-08-10
**Branch**: `jaredfholgate-align-e2e-retry-patterns`

## Outcome

Preserve exact parity with the legacy Porch retry regex introduced by
[Azure/avm-terraform-governance#529](https://github.com/Azure/avm-terraform-governance/pull/529),
then classify `LocationNotAvailableForResourceGroup` apply failures as
retryable.

## Checklist

- [x] Compare every built-in retry pattern with the merged Porch configuration.
- [x] Add the unavailable resource-group location pattern.
- [x] Add regression coverage for the reported Terraform error.
- [x] Run the repository pre-commit gate.
- [x] Commit, push, and open the pull request.

## Validation

- Confirmed the original six expressions exactly match the merged Porch regex,
  in the same order and with case-insensitive matching.
- `./build.ps1 pre-commit` passed.

## Blockers or dependencies

None.
