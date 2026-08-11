# Staged managed-file rollout rings

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `myaschmitz-fuzzy-doodle`

## Outcome

Restore the staged rollout ladder for managed files so a change can reach
`avm-ptn-example-repo` first, then the ten-repository canary cohort, then every
managed repository, without editing `config.json` between rings.

Both overlay directories already exist and the stacking engine already supports
them; only the `managedFilesAdditional` pointers were missing. Legacy governance
pull requests #516 and #546 removed those pointers when the previous experiments
graduated to `root`, which left the mechanism dormant rather than deleted.

Restoring both pointers while the overlay directories contain only `.gitkeep` is
behaviourally inert, because `Add-AvmManagedFilesFromDir` filters that
placeholder. Once wired, promotion between rings is a pure `git mv` of the
managed file, so no ring transition requires a configuration change that could be
left half-applied.

## Ring ladder

| Ring | Directory under `repository-management/managed-files/files/` | Repositories |
| ---- | ------------------------------------------------------------ | ------------ |
| 1    | `canary-tooling/`                                              | `avm-ptn-example-repo` only |
| 2    | `canary/`                                                      | the ten canary repositories |
| 3    | `root/`                                                        | every managed repository |

## Checklist

- [x] Confirm the overlay stacking engine and its ordering tests already exist.
- [x] Confirm empty overlays contribute no files, so wiring is inert.
- [x] Restore `managedFilesAdditional` on the `canary` group with order `10`.
- [x] Add the `canary-tooling` group with order `20` and the example repository.
- [x] Document the ring ladder and the delete-on-promote rule.
- [x] Add regression coverage pinning the wired ring order.
- [x] Run focused and pre-commit validation.
- [x] Commit and push the slice.

## Design notes

`canary` keeps its existing ten repositories and its `canary` topic unchanged.
`avm-ptn-example-repo` belongs to both groups, so at ring 1 it resolves overlays
`canary` then `canary-tooling` while the other nine canary repositories resolve
`canary` alone. No cohort membership is edited during a rollout, so there is no
temporary state to restore.

Promotion must move the file rather than copy it. Overlays win over `root`, so a
copy left behind in a lower ring keeps overriding `root` for that ring's
repositories indefinitely. The symptom is that the fleet updates correctly while
the repository used for testing stays on the old version.

`Resolve-RepositorySettings` in the repository-sync library and
`Resolve-AvmManagedFilesRepositorySetting` in `Avm.Authoring` implement the same
ordering. Both are exercised so `avm pr-check` drift detection agrees with what
the sync pipeline writes.

## Validation

`tests/Pester/Unit/RepositoryManagement/ManagedFileRollout.Tests.ps1` resolves the
real checked-in `config.json` through both resolvers rather than a synthetic
fixture, so a dropped pointer or a reordered overlay fails the build.

- `./build.ps1 test` — 902 passed, 0 failed, 7 skipped, including the seven new
  ring assertions.
- `repository-management/repository-sync/scripts/Test-RepositoryConfig.ps1` —
  passed.
- `./build.ps1 pre-commit` — layout, lint, and unit tests passed. Two component
  tests (`pr-check composes eight steps`, `pr-check rejects a shell hook`) fail
  on this workstation only because tflint ships no `windows-arm64` release, which
  is unrelated to this slice and reproduces on `main`.

## Status update

Complete. Both pointers are wired and inert, so the next managed-file change can
be authored directly in `canary-tooling/` and promoted by moving it.

## Blockers or dependencies

None. The overlay directories, the stacking engine, and the ordering tests were
all migrated intact; this slice only restores the configuration pointers.
