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
| Pin contents | Tag version, source repo, resolved commit hash, commit date, and update timestamp |
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
  "commitDate": "2026-08-10T14:02:11Z",
  "updatedAt": "2026-08-12T10:30:00Z"
}
```

`version` is semver without a leading `v`, matching the convention already
documented in `Resources/avm.pins.jsonc`. The git tag is derived as `v$version`.
`commitDate` is the committer date of the tagged commit and `updatedAt` is when
the pin was last stamped, so a reader can tell how old the release is
independently of when this repository adopted it. Both are ISO 8601 UTC.

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

- [x] Add `.avm-managed-lines.json` to the `root` group in the managed-files
      repository, removing `.avm` and requiring `.avm/managed-files.json` so the
      local override stays untracked.
- [x] Confirm no interaction with `avm.tf.gitignore-essentials`. The rule's 23
      required globs do not include `.avm`, so the removal cannot fight it.
- [x] Verify `Get-AvmManagedLinePlan` creates `.gitignore` when absent. Covered
      by `Merge-AvmFileLine.Tests.ps1` ("creates a plan for a missing file with
      LF endings").

Lands in `Azure/azure-verified-modules-managed-files`, not this repository:
[managed-files#8](https://github.com/Azure/azure-verified-modules-managed-files/pull/8).

Validated by running the real `Get-AvmManagedLineSpec` and
`Get-AvmManagedLinePlan` against the live `.gitignore` of
`Azure/terraform-azurerm-avm-res-storage-storageaccount`: the plan reports
`removed=[.avm]` and `added=[.avm/managed-files.json]`, the bare `.avm` line is
gone, and a second pass reports `Changed=False`.

**This pull request must merge before the first semver release is cut**,
otherwise the pin is gitignored in every module repository.

### Phase 2 — version primitives

- [x] `AvmManagedFilesVersionException` (`AVM1060`) and a non-terminating
      lookup-failure exception alongside `AvmGalleryLookupException`.
      `AvmManagedFilesLookupException` mirrors the gallery equivalent and
      derives directly from `AvmException`; `AvmManagedFilesVersionException`
      carries exit code 11.
- [x] `Get-AvmLatestManagedFilesVersion`, `Get-AvmManagedFilesVersionPin`,
      `Set-AvmManagedFilesVersionPin`, `Test-AvmManagedFilesVersion`, plus
      `Get-AvmManagedFilesVersionPinPath` for the shared path contract.
- [x] Unit tests for semver ordering, peeled-tag filtering, malformed pins, and
      the offline path. 30 tests across four files under
      `tests/Pester/Unit/Private/`.

### Phase 3 — sync integration

- [x] Add the pin to the `$pick` precedence chain in `Sync-AvmManagedFile`.
- [x] Add `-Upgrade` and `-SkipManagedFilesVersionCheck` parameters.
- [x] Capture the resolved commit and its committer date via
      `git rev-parse HEAD` and `git show -s --format=%cI` on the checkout so the
      pin records provenance.
- [x] Stamp the pin on `-Upgrade` and on the unpinned bootstrap, never in
      `-CheckDrift`.
- [x] Surface both parameters through `Invoke-AvmSync`.

### Phase 4 — pre-commit and pr-check

- [x] Extend `$syncParameterNames` in `Invoke-AvmPreCommit` with the new
      parameters. The derived-surface test filters to `[string]` parameters, so
      the two switches needed dedicated forwarding tests rather than being
      picked up automatically.
- [x] Catch `AvmManagedFilesVersionException` explicitly in `Invoke-AvmPreCommit`
      and map it to `fail` rather than `error`, with an actionable message. The
      chain continues past the failed step, matching `AvmConfigurationException`.
- [x] Fail `pr-check` on an unadopted major. No code change was required:
      `Invoke-AvmPrCheck` runs the sync step with `-CheckDrift`, and Phase 3
      already raises a sync issue against `.avm/managed-files-version.json` for a
      superseded major, which forces the step to `fail` and propagates to the
      overall result. Only the comment-based help was updated.
- [x] No CLI dispatch work was needed. `Invoke-Avm` strips leading dashes,
      converts kebab-case to PascalCase, and treats `SwitchParameter` as a
      valueless flag, so `avm pre-commit -upgrade`, `--upgrade` and
      `--skip-managed-files-version-check` all bind unchanged.
- [x] Tests for the warn, error and upgrade paths. Placed at the unit tier
      (engine plan branching plus pre-commit chain behaviour) and the integration
      tier, not the component tier: `Get-AvmLatestManagedFilesVersion` builds
      `https://github.com/<repo>.git` in the module, so a component fixture
      cannot substitute a local remote, and the existing component fixtures pass
      `-ManagedFilesLocalPath`, which short-circuits version enforcement by
      design. `tests/Pester/Integration/ManagedFilesVersion.Integration.Tests.ps1`
      covers real tag discovery, the unpinned bootstrap plan, the behind-branch
      message, and the on-disk pin round-trip.

### Phase 5 — repository sync

- [x] Stop passing `-managedFilesBaseDir` in
      `.github/workflows/repository-management-sync.yml` so each repository
      resolves its own pinned ref through the ref-keyed cache. The
      `Checkout managed files repository` step and the `-managedFilesBaseDir`
      argument are both gone, and `Invoke-RepositorySync.ps1` no longer accepts
      the parameter.
- [x] Kept `-ConfigLocalPath`. This deviates from the original plan wording,
      which grouped the config local path with the managed-files local path. The
      reason for dropping the managed-files path does not apply to the config
      path: `Resolve-AvmManagedFilesSource` short-circuits to `SourceKind='local'`
      only on `ManagedFilesLocalPath`, so the config path never suppresses version
      resolution, and the repository config genuinely lives in this repository
      rather than in a versioned release.
- [x] Implement the open-pull-request staleness gate in
      `lib/ManagedFilesUpgrade.ps1`. `Resolve-AvmManagedFilesUpgradeDecision`
      reads the repository's pin, discovers the newest release with
      `git ls-remote --tags`, and only queries `gh pr list` when the delta is a
      minor or patch. The decision is an explicit pre-flight check rather than an
      exception-driven retry, so the reason is logged on every repository,
      including in plan-only mode.
- [x] Pass `-Upgrade` only when unblocked or when the delta is a major. A major
      is evaluated before the pull-request query, so a forced upgrade never spends
      a `gh` call and can never be blocked. Lookup failures on either side fall
      back to the pinned version rather than failing the sync.
- [x] Cover the gate with tests, including the bot-author and draft exclusions.
      `Test-ManagedFilesUpgrade.ps1` covers pin reading, tag parsing and sorting
      (including non-semver tags), the 14-day staleness boundary either side, bot
      and draft exclusion, major-overrides-blocking, and both lookup failures.
      `Test-AvmPreCommit.ps1` now asserts the `Upgrade` switch is absent by
      default and forwarded when requested. Both are registered in
      `.github/workflows/repository-management-config-test.yml`.

### Phase 6 — rollout and documentation

- [ ] Cut `v1.0.0` of the managed-files repository manually. **Blocked on
      [managed-files#8](https://github.com/Azure/azure-verified-modules-managed-files/pull/8)
      merging first.**
- [ ] First repository sync stamps a pin into every module repository.
- [x] Update `docs/avm-implementation-spec.md` with the pin file, the precedence
      tier, and `AVM1060`. §8 now lists `managed-files-version.json`, carves it
      out of the read-only rule, and adds a "Managed-file version pin" section
      covering the schema, the five-tier ref precedence, the fact that tiers 1–3
      disable enforcement, and the enforcement matrix. §14 gains `AVM1050`/exit
      10 and `AVM1060`/exit 11, and the exit-code reservations move to `12–19`
      to stop claiming codes that are already allocated. §20 gains a
      "Managed-files releases" section covering the release cadence and the
      fleet-sync gate, and §24 defines the pin in the glossary.
- [x] Propose a matching change to `Azure-Verified-Modules-Docs`, checking for an
      open pull request first. No open pull requests existed, so a new branch
      `users/jaredfholgate/managed-files-versioning` carries
      [Docs#37](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/37):
      a new how-to, `Manage Managed-File Versions and Releases (Terraform)`, plus
      a correction to `deploy-canary-managed-file-update.md`, which claimed
      content always comes from managed-files `main` and that nothing overrides
      that. It now describes pinned delivery, gains a "Cut a release" section,
      and carries release steps through both ring promotions, the rollback, and
      the worked example. `docfx --warningsAsErrors` and
      `Test-DocsNavigation.ps1` both pass.

## Validation

Phases 1, 2, 3, 4 and 5 complete.

- `./build.ps1 pre-commit` — 949 unit tests, 28 component tests, 0 errors.
- 30 unit tests cover the version primitives; 17 cover the version plan
  resolver; 4 cover the sync engine's version branching (major throws, major
  under `-CheckDrift` becomes a drift issue, stamp on demand, never stamp under
  `-CheckDrift`).
- 4 unit tests cover the `Invoke-AvmPreCommit` surface: both switches are
  exposed, both are forwarded to the terraform sync step, neither is forwarded
  when unsupplied, and a superseded major becomes a failed step that leaves the
  remaining four steps running.
- 4 integration tests (`ManagedFilesVersion.Integration.Tests.ps1`, tagged
  `Integration`, skipped under `AVM_OFFLINE`) run against the live repository:
  real tag discovery through `git ls-remote`, the unpinned bootstrap plan, the
  behind-branch message for a stale pin, and the on-disk pin round-trip
  including the no-BOM / LF / trailing-newline encoding contract.
- The repository-sync harness scripts pass:
  `Test-ManagedFilesUpgrade.ps1` (upgrade decision, tag discovery, pull-request
  filtering) and `Test-AvmPreCommit.ps1` (switch forwarding and the existing
  upgrade-retry behaviour).
- End-to-end smoke test against the live managed-files repository: an unpinned
  repository adopted `v0.1.0`, stamped `.avm/managed-files-version.json` with
  the commit and committer date, and a second run reported `status=upToDate`
  against `ref=v0.1.0` without rewriting the pin.

## Dependencies

- Phase 1 lands in `Azure/azure-verified-modules-managed-files`:
  [managed-files#8](https://github.com/Azure/azure-verified-modules-managed-files/pull/8).
  Must merge before any release is cut.
- Phase 6 depends on a manual release in that repository.
- The managed-files repository has five open Dependabot pull requests, which are
  useful live test data for the phase 5 exclusion rule.
- Documentation:
  [Docs#37](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/37)
  describes behaviour that ships with
  [tools#65](https://github.com/Azure/azure-verified-modules-tools/pull/65), so it
  should not merge ahead of it.

## Open questions

- **Canary changes now need a release each.** Delivery is gated on a published
  tag, so every canary ring promotion and every rollback needs its own release.
  Should each canary change get a normal release, or should pre-release tags
  (`v1.1.0-rc.1`) be supported for soaking? The semver sort does not currently
  handle pre-release identifiers.
- **A canary repository can block its own canary.** If the ring repository has an
  open, non-stale, non-bot pull request, a patch or minor release will not reach
  it and the canary silently does nothing. There is no targeted "force this
  repository's pin" mechanism; a workflow input would be the obvious addition.
- **Overridden repositories are silent on a major.** When a repository sets an
  explicit ref through tiers 1–3, version enforcement is disabled entirely, so an
  unadopted major produces no warning at all.
