# Repository sync force update

**Status**: complete
**Started**: 2026-08-19
**Updated**: 2026-08-19
**Branch**: `jaredfholgate-repo-sync-force-file-update`

## Outcome

Allow a manual repository-sync dispatch to force managed-file updates for a
selected subset of repositories without requiring a new managed-files major
version. Remove the ineffective direct-access force-removal workflow input and
its associated implementation. Repair repositories where a legacy root `.avm`
file prevents creation of the managed-files metadata directory.

## Checklist

- [x] Add and validate a dispatch-only force-update input.
- [x] Apply the forced update only to the selected repositories.
- [x] Remove the direct-access force-removal input and implementation.
- [x] Remove a conflicting root `.avm` file before managed-file sync.
- [x] Cover the changed workflow and script behaviour with tests.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit, push, and open a pull request.

## Validation

- Run `32234329971`, job `96010930499` failed because
  `.avm/managed-files-version.json` could not be created beneath a root `.avm`
  file.
- Both `terraform-azurerm-avm-res-datafactory-factory` and
  `terraform-azurerm-avm-ptn-confidential-compute` expose the same 5,130-byte
  `.avm` file at `main`.
- The repository-sync configuration tests passed, including force-update input
  wiring, managed-files upgrade decisions, `.avm` file removal, and direct
  collaborator handling.
- `./build.ps1 pre-commit` passed: 981 unit tests passed with 8 skipped, and 28
  component tests passed.

## Blockers or dependencies

None.
