# Staged managed-file rollout rings

Status: complete
Started: 2026-08-11
Completed: 2026-08-11
Branch: myaschmitz-staged-managed-file-rollout-rings

## Outcome

Managed files can reach `avm-ptn-example-repo` first (`canary-tooling`, order 20),
then the ten canary repositories (`canary`, order 10), then every managed
repository (`root`), with promotion done by `git mv` rather than a config edit.

Both `managedFilesAdditional` pointers existed before and were removed when
earlier experiments graduated (legacy governance PRs #516 and #546); the overlay
engine itself migrated intact. Restoring them is inert while the overlay
directories hold only `.gitkeep`, because `Add-AvmManagedFilesFromDir` filters
that placeholder.

Promotion must move the file, never copy it. Overlays beat `root`
unconditionally, so a copy left in a lower ring keeps overriding `root` for that
ring indefinitely; the symptom is the fleet updating while the repository used
for testing stays behind.

## Checklist

- [x] Restore `managedFilesAdditional` and order `10` on the `canary` group.
- [x] Add the `canary-tooling` group at order `20` scoped to the example repo.
- [x] Document the ring ladder and the move-never-copy rule in the README.
- [x] Add regression coverage pinning the wired order against the real config.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit` — layout, lint, and unit pass. Unit: 902 passed,
  0 failed, 7 skipped.
- `repository-management/repository-sync/scripts/Test-RepositoryConfig.ps1` — passed.
- `tests/Pester/Unit/RepositoryManagement/ManagedFileRollout.Tests.ps1` resolves
  the real `config.json` through both `Resolve-RepositorySettings` and
  `Resolve-AvmManagedFilesRepositorySetting` and asserts they agree, so the sync
  pipeline and `avm pr-check` drift detection cannot diverge.
- Two component tests (`pr-check composes eight steps`, `pr-check rejects a shell
  hook`) fail on this workstation only, because tflint ships no `windows-arm64`
  release. Unrelated to this slice; reproduces on `main`.

## Blockers or dependencies

- None.
