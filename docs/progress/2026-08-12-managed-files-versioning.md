# Managed files versioning

**Status**: in-progress
**Started**: 2026-08-12
**Updated**: 2026-08-12
**Branch**: `jaredfholgate-managed-files-versioning`

## Outcome

Version the managed-file overlays in
`Azure/azure-verified-modules-managed-files` with semver tags, and pin every
module repository to a specific version. `avm pre-commit` syncs to the pinned
version and warns about newer minor/patch releases; a newer major becomes a hard
error that directs the author at `avm pre-commit -Upgrade`. `avm pr-check`
validates against the pin and fails when an unadopted major exists. Repository
sync only bumps the pin when the target repository has no open human pull
request, unless the release is a major.

This document is the agreed design for the whole feature. Each implementation
phase below may open its own `docs/progress/` slice file; this file tracks the
overall shape and the decisions behind it.

## Decisions

Confirmed with the requester on 2026-08-12.

| Question | Decision |
| --- | --- |
| Where does the pin live? | `.avm/managed-files-version.json`, kept separate from the existing `.avm/managed-files.json` local override |
| `.avm` is currently gitignored | Remove it via the managed-line spec; it is a pre-existing bug that also blocks `.avm/context.psd1` and `.avm/rules/*.psd1` |
| Pin contents | Tag version, source repo, resolved commit hash, and update timestamp |
| `pre-commit` default behaviour | Sync to the **pinned** version; warn on newer minor/patch; error on newer major and prompt for `-Upgrade` |
| Staleness window | 14 days, measured on pull request `updatedAt` |
| Non-blocking pull requests | Dependabot, any `Bot` author, and drafts |
| Repository with no pin | Adopt latest and stamp it silently; treat as up to date |
| Latest-version discovery | `git ls-remote --tags` plus semver sort — no auth, no rate limit |
| Lookup failure / offline | Warn and continue against the pin, in both `pre-commit` and `pr-check` |
| Release automation | Out of scope; releases stay manual in the GitHub UI |

## Context

Three findings from reconnaissance shape the design.

**`.avm` is gitignored in module repositories, and that is a latent bug.** The
directory holds only committed configuration — `context.psd1`, `rules/*.psd1`,
`managed-files.json`, and the `.disable` sentinel. Nothing in `src/` writes cache
or temporary data into a repository's `.avm/`; every cache, tool, state, and log
path resolves outside the repository through `Get-AvmFolder`. Today
`.avm/context.psd1` and `.avm/rules/*.psd1` cannot be committed without
`git add -f`, so removing the ignore fixes an existing defect as well as
unblocking the pin.

**A line-merge mechanism already exists and is unused.** `Merge-AvmFileLine.ps1`
supports both `required` and `removed` lines through an
`.avm-managed-lines.json` spec placed in a managed-files overlay group, stacking
across groups exactly like files do. No group ships a spec yet, so this feature
is its first consumer. The separate `avm.tf.gitignore-essentials` convention rule
is append-only and does not list `.avm`, so the two do not collide.

**Repository sync currently bypasses ref resolution entirely.** The workflow
checks the managed-files repository out at its default branch and passes
`-managedFilesBaseDir`, which sets `ManagedFilesLocalPath` and short-circuits the
git fetch in `Resolve-AvmManagedFilesSource`. A single shared checkout cannot
serve repositories pinned to different versions, so the local-path override has
to go (see phase 5).

## Design

### Pin file

`.avm/managed-files-version.json` at the repository root:

```json
{
  "version": "1.2.3",
  "repo": "Azure/azure-verified-modules-managed-files",
  "commit": "0f1e2d3c4b5a69788796a5b4c3d2e1f00fedcba9",
  "updatedAt": "2026-08-12T10:30:00Z"
}
```

`version` is semver without a leading `v`, matching the convention already
documented in `Resources/avm.pins.jsonc`. The git tag is derived as `v$version`.

### Ref precedence

`Sync-AvmManagedFile` gains the pin as a new tier in the existing `$pick`
precedence chain, below every explicit override so tests and CI can still force
a ref, and above the hardcoded default:

1. Explicit `-ManagedFilesRef` parameter
2. `AVM_MANAGED_FILES_REF` environment variable
3. `ref` key in `.avm/managed-files.json`
4. **`version` in `.avm/managed-files-version.json`, as tag `v$version`** (new)
5. Hardcoded `main` default

Because `Get-AvmManagedFilesCheckout` keys its cache on the ref and `git clone
--branch` accepts a tag, pinning is a small delta on existing machinery and
immutable tags cache perfectly.

### Version comparison

New private helpers under `Private/Version/`, mirroring the established
`Test-AvmModuleVersion` / `Get-AvmLatestModuleVersion` pair:

| Function | Responsibility |
| --- | --- |
| `Get-AvmLatestManagedFilesVersion` | `git ls-remote --tags`, discard peeled `^{}` entries, semver sort, return the highest. `$script:`-scoped cache with `-Refresh`. |
| `Get-AvmManagedFilesVersionPin` | Read and validate the pin file; return `$null` when absent. |
| `Set-AvmManagedFilesVersionPin` | Write the pin, UTF-8 without BOM and LF. `SupportsShouldProcess`. |
| `Test-AvmManagedFilesVersion` | Classify the delta as `upToDate`, `patch`, `minor`, `major`, `unpinned`, or `unknown`. |

`unknown` is the offline and lookup-failure result. It warns and proceeds
against the pin, matching how a PowerShell Gallery lookup failure is handled
today.

New exception `AvmManagedFilesVersionException : AvmException` with code
`AVM1060` (the next free code after `AVM1050`), carrying `PinnedVersion`,
`LatestVersion`, and an exit code. The typed exception is what lets repository
sync special-case a major the same way it already special-cases `AVM1050`.

### Behaviour matrix

| Delta | `pre-commit` | `pre-commit -Upgrade` | `pr-check` | Repository sync |
| --- | --- | --- | --- | --- |
| Up to date | Sync at pin | Sync at pin, no pin change | Drift check at pin | Sync at pin |
| Patch / minor | Sync at pin, **warn** | Sync at latest, **stamp pin** | Drift check at pin, warn | Upgrade only when unblocked |
| Major | **Throw `AVM1060`**, no sync | Sync at latest, **stamp pin** | **Fail** | Always upgrade |
| Unpinned | Sync at latest, **stamp pin** | Sync at latest, stamp pin | Drift check at latest, **no write**, warn | Sync at latest, stamp pin |
| Lookup failed | Sync at pin, warn | Fail (cannot resolve a target) | Drift check at pin, warn | Sync at pin, warn |

The `pr-check` unpinned cell is the one asymmetry worth care:
`Assert-AvmGitWorkingTreeClean` runs first, so `pr-check` must never stamp a pin.
It resolves latest, checks drift against it, and warns.

### Repository sync gate

The gate wraps the upgrade decision, not the sync itself. In
`Invoke-AvmPreCommitForRepository`, before the existing `gh pr create`:

1. Classify the delta for the target repository.
2. A major always upgrades.
3. Otherwise query `gh pr list --repo <r> --state open --json number,updatedAt,isDraft,author`.
4. Discard drafts and any author where `author.is_bot` is true.
5. A remaining pull request with `updatedAt` inside 14 days blocks the upgrade.
6. Blocked repositories still run pre-commit **at the pinned version**, so
   ordinary drift repair continues to open pull requests as it does today. Only
   the pin bump is deferred.

## Phases

Each phase is a separate commit, and phases 1-2 are a prerequisite for the rest.

### Phase 1 — un-ignore `.avm`

- [ ] Add `.avm-managed-lines.json` to the `root` group in the managed-files
      repository, removing `.avm` and requiring `.avm/managed-files.json` so the
      local override stays untracked.
- [ ] Confirm no interaction with `avm.tf.gitignore-essentials`.
- [ ] Verify `Get-AvmManagedLinePlan` creates `.gitignore` when absent.

Lands in `Azure/azure-verified-modules-managed-files`, not this repository.

### Phase 2 — version primitives

- [ ] `AvmManagedFilesVersionException` (`AVM1060`) and a non-terminating
      lookup-failure exception alongside `AvmGalleryLookupException`.
- [ ] `Get-AvmLatestManagedFilesVersion`, `Get-AvmManagedFilesVersionPin`,
      `Set-AvmManagedFilesVersionPin`, `Test-AvmManagedFilesVersion`.
- [ ] Unit tests for semver ordering, peeled-tag filtering, malformed pins, and
      the offline path.

### Phase 3 — sync integration

- [ ] Add the pin to the `$pick` precedence chain in `Sync-AvmManagedFile`.
- [ ] Add `-Upgrade` and `-SkipManagedFilesVersionCheck` parameters.
- [ ] Capture the resolved commit via `git rev-parse HEAD` on the checkout so the
      pin records provenance.
- [ ] Stamp the pin on `-Upgrade` and on the unpinned bootstrap, never in
      `-CheckDrift`.
- [ ] Surface both parameters through `Invoke-AvmSync`.

### Phase 4 — pre-commit and pr-check

- [ ] Extend `$syncParameterNames` in `Invoke-AvmPreCommit` with the new
      parameters; `Test-AvmPreCommit.ps1` derives the expected surface from
      `Sync-AvmManagedFile`, so this is enforced by test.
- [ ] Catch `AvmManagedFilesVersionException` explicitly in `Invoke-AvmPreCommit`
      and map it to `fail` rather than `error`, with an actionable message.
- [ ] Fail `pr-check` on an unadopted major.
- [ ] Component tests covering warn, error, and upgrade paths.

### Phase 5 — repository sync

- [ ] Stop passing `-managedFilesBaseDir` / config local paths in
      `.github/workflows/repository-management-sync.yml` so each repository
      resolves its own pinned ref through the ref-keyed cache.
- [ ] Implement the open-pull-request staleness gate in
      `lib/AvmPreCommit.ps1`.
- [ ] Pass `-Upgrade` only when unblocked or when the delta is a major.
- [ ] Cover the gate with tests, including the bot-author and draft exclusions.

### Phase 6 — rollout and documentation

- [ ] Cut `v1.0.0` of the managed-files repository manually.
- [ ] First repository sync stamps a pin into every module repository.
- [ ] Update `docs/avm-implementation-spec.md` with the pin file, the precedence
      tier, and `AVM1060`.
- [ ] Propose a matching change to `Azure-Verified-Modules-Docs`, checking for an
      open pull request first.

## Validation

Not yet run; this document currently records design only.

## Dependencies

- Phase 1 lands in `Azure/azure-verified-modules-managed-files`.
- Phase 6 depends on a manual release in that repository.
- The managed-files repository has five open Dependabot pull requests, which are
  useful live test data for the phase 5 exclusion rule.
