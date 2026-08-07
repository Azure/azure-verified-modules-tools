# Changelog

All notable changes to `Avm.Authoring` will be documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

The release pipeline (`release-avm-authoring.yml`, in Azure DevOps) takes the git
tag as the single source of truth for the version: it stamps the tag version into
the staged manifest at build time, so `ModuleVersion` in the repo never has to be
bumped before tagging. If a section matching the tag exists (e.g. tag `v0.1.0`
→ section `## [0.1.0]`) it seeds the gallery release notes; otherwise the manifest
keeps its standing CHANGELOG pointer. A missing section does not fail the release.
The GitHub Release body is written by hand — see `CONTRIBUTING.md` §8.

## [Unreleased]

Bullets below describe work that shipped untagged in `0.1.3` and `0.1.4`, which
were both cut without CHANGELOG sections. Move new bullets into a dated version
section when cutting a release.

### Added

- Pin manifest tests now assert that every `tests/fixtures/bin/*.ps1` stub
  self-reports the version pinned in `avm.pins.jsonc`, so a stale stub fails at
  its cause instead of surfacing as an unrelated Component-tier PATH miss.
- `avm update` safely upgrades Avm.Authoring in the CurrentUser scope. It reuses
  the cached PowerShell Gallery version lookup, reports when already current,
  supports `-WhatIf`, and remains available when the running module is stale.
- Enforce the latest PowerShell Gallery release at every public command entry point. Confirmed stale versions fail with exit code 10 and an upgrade command; `-SkipModuleVersionCheck` warns and continues, as do Gallery lookup failures.
- `avm check policy` for Terraform now evaluates each runnable `examples/*`
  directory against real `terraform show -json` output. The lifecycle honours
  `.e2eignore`, `pre.ps1`, `.env`, `post.ps1`, pinned
  default exemptions, and example-local `exceptions/`, then runs the pinned
  APRL and AVMSEC bundles separately with all namespaces enabled.
- `avm lint` runs an optional `tflint-pre.ps1` hook in each direct example
  before TFLint initializes its plugins and evaluates that example.
- `pinned-assets.psd1` configuration reader (`Get-AvmPinnedAsset`) and cache
  materialiser (`Resolve-AvmPinnedAsset`) that honour `AVM_OFFLINE` and
  `AVM_MIRROR` and reuse the existing `Get-AvmFolder` cache layout.
- `conftest` (0.68.2) pinned in `tools.lock.psd1` for all six OS/arch
  platforms; resolvable through the standard managed-tool resolver.
- `AvmAvoidStringThrow` custom PSScriptAnalyzer rule that flags
  `throw "string"` in `src/Avm.Authoring/**` and steers code toward the typed
  `AvmException` hierarchy. Wired into `./build.ps1 lint` (and therefore the
  `pre-commit` / `ci` chains).
- `AVM_NO_CONSOLE_CONFIG` env-var opt-out for the host PSReadLine prediction
  shim, for CI and script callers that can't tolerate console-config probing.

### Changed

- PSGallery publication now runs in GitHub Actions after ADO uploads and
  promotes the ESRP-signed release. The workflow publishes the signed release
  archive without rebuilding it and validates its checksum, archive layout,
  module version, casing, and signature blocks first.
- Pinned `mapotf` bumped to 0.1.7, with refreshed per-platform SHA256 hashes.
  Neither 0.1.6 nor 0.1.7 carries a functional change — both move mapotf's own
  release signing to ESRP — but its Windows binaries are now
  Authenticode-signed, so `mapotf.exe` should stop tripping Defender's ML
  heuristics.
- Pinned `terraform` bumped to 1.15.8 and `mapotf` to 0.1.5 in
  `Resources/avm.pins.jsonc`, with refreshed per-platform SHA256 hashes.
- `avm lint` now copies the Terraform module to a cleaned temporary tree and
  runs `terraform init -input=false` in every root, module, and example scope.
  Example `tflint-pre.ps1` hooks run after Terraform initialization and before
  TFLint plugin initialization, while generated files and hook output remain
  isolated from the source repository.
- `avm pr-check` no longer repeats the standalone `unit-test` CI job. Unit,
  integration, and end-to-end test commands report `skipped`, not `pass`, when
  no matching tests are discovered.
- Shell lifecycle hooks are rejected with an actionable configuration error.
  Module authors must refactor `pre.sh`, `post.sh`, and `tflint-pre.sh` hooks
  to their corresponding PowerShell `.ps1` form.
- Policy cleanup still attempts `post.ps1` after Terraform or Conftest fails,
  but a post-hook failure no longer replaces the primary tool diagnostic and
  is reported as a secondary warning.
- The release workflow no longer requires `ModuleVersion` in the repo manifest
  to match the tag being released, and no longer fails when the tag has no
  CHANGELOG section. `./build.ps1 build -ReleaseVersion X.Y.Z` stamps the
  version (and the matching CHANGELOG section, when present) into the staged
  manifest under `out/`; the in-repo manifest is never rewritten.
- `Invoke-AvmBicepDocs` reverted to a clean `AvmConfigurationException` stub
  on 2026-05-26 in a deliberate pivot to prioritise Terraform-first delivery.
  The intervening ARM-JSON walker spike (slices 4a–4f: outputs, resource-types,
  Parameters summary, per-parameter detail blocks, inline-object recursion,
  `$ref`/UDT resolution, array `items` traversal, discriminated-union
  dispatch, and the secure-type contract) was implemented end-to-end and then
  removed wholesale. A future design will shell out to a dedicated Bicep docs
  CLI when one is selected.
- `docs/avm-consolidation-plan.md` verb-table entries for `avm docs` (Bicep),
  `avm pre-commit`, and `avm pr-check` rewritten to match the engines as
  wired today (`format → lint → test → docs` for `pre-commit`;
  clean-worktree preflight then
  `sync → format → transform → lint → check policy → check convention → validate → docs`
  for `pr-check`, with unit tests retained as a separate CI job).

### Fixed

- Real-binary Terraform integration tests keep their self-owned Windows home
  and fixture work tree under `%LOCALAPPDATA%\Avm\IntegrationTests` instead of
  `%TEMP%`, reducing Defender ML false positives against unsigned `mapotf.exe`.
- Latest-version discovery now uses `Find-PSResource` and validates empty or
  malformed results without leaking internal PowerShell runtime errors into
  warnings. Repository tests suppress the public version gate centrally, while
  focused unit and integration coverage still exercises the live lookup.
- `avm version` reads prerelease metadata from dictionary-backed and
  property-backed module data without positional string indexing, and dispatcher
  routes perform the Gallery version check only once.
- CI and release prerequisite installation retries bounded PSGallery network and
  service failures, while deterministic package errors still fail immediately.
- `avm pr-check` now fails before its tool chain when `git status
  --porcelain` reports tracked or untracked changes, restoring the legacy
  clean-worktree preflight.
- Repository-root `avm.tflint.override.hcl`,
  `avm.tflint_example.override.hcl`, and
  `avm.tflint_module.override.hcl` files are merged over the vendored rulesets
  before TFLint runs. Migrated repositories no longer silently lose their
  ruleset customizations.
- `avm check policy` no longer feeds raw HCL to policies designed for Terraform
  plan JSON. The old path could not match a resource and therefore reported
  `skipped` in every PR check. Policy evaluation now uses isolated per-example
  plans, keeps each example's exceptions scoped locally, and has executable
  failure coverage for both APRL and AVMSEC.

### Tests

- Real-binary pr-check fixtures are initialized as clean committed Git
  repositories before the gauntlet runs, so the integration tier exercises the
  restored dirty-worktree preflight instead of failing setup with "not a git
  repository". Staged legacy `pre.sh` / `post.sh` duplicates are removed where
  the canonical fixture already provides equivalent PowerShell hooks.
- Terraform engine stub harness under `tests/Pester/Integration/Terraform/`
  that exercises `Invoke-AvmPreCommit` and `Invoke-AvmPrCheck` end-to-end
  against stub `terraform` / `tflint` / `terraform-docs` / `conftest`
  binaries injected onto the PATH.
- End-to-end coverage of `Invoke-AvmCheckPolicy` (Terraform) via a stub
  `conftest` binary that simulates pass, deny, and exception-suppression
  scenarios.
- Public-verb smoke test for the `Invoke-AvmPreCommit` composition (covers
  Terraform alongside the existing Bicep coverage).
- PSScriptAnalyzer rule-test helper made array-safe to remove a CI flake.

### Docs

- Root `README.md` refreshed to reflect the actual repo state after the
  2026-05-26 Terraform-first pivot.
- New `docs/terraform-migration.md` migration guide.
- `docs/progress.md` audit of Terraform tool binary availability — 3 of 4
  candidates (`mapotf`, `avmfix`, `grept`) ship no GitHub releases, blocking
  `avm transform` / `avm check convention` / the `avmfix`-format-chain on an
  A/B/C supply-chain decision.
- Confirmed the spec §19 pre-commit Pester suite is ghost-complete (no
  additional test work required to satisfy that line item).
- `AVM_NO_CONSOLE_CONFIG` documented in the host shim README/inline help.

## [0.1.8] - 2026-08-03

Log-fidelity round from post-release failure-path testing of `0.1.7` against the
canary repo `Azure/terraform-azurerm-avm-ptn-example-repo` (F57, F58). Both
defects were found by deliberately injecting ordinary mistakes — a typo in a
`.tf` file, and format drift alongside a broken test — and reading what the
tooling actually reported.

### Fixed

- **Tool failures now report what the tool said.** `Invoke-AvmProcess` built its
  exception message from the exit code and the command line alone, so a
  malformed `.tf` file produced `Process exited with code 2: terraform.exe fmt
  ...` and nothing else. The stderr was captured and attached to the exception
  the whole time, but the only code that rendered it was gated on narration, and
  `terraform fmt` does not narrate. The message now carries the tool's own
  diagnostic — file, line and reason — bounded to 20 lines / 2000 characters.
  This affects every managed tool: terraform, tflint, terraform-docs, conftest
  and mapotf. (F57)
- **The single GitHub Actions annotation now names the most severe failure, not
  the first one.** `pr-check` emits one annotation per run (deliberately, so the
  Files-changed view is not buried). It was selected by step order, so a run with
  both `terraform_variable_separate` lint nits and four broken unit tests
  annotated the nit and left twelve `error` diagnostics unannotated. Selection is
  now severity-ranked. Within a step, position still wins so the F24b headline
  behaviour is unchanged; across steps, severity wins so a real error outranks a
  positioned style nit. (F58)

  A second defect surfaced in the same measurement: within the lint step the
  first positioned issue was chosen, which is an `info` finding — but lint gates
  on `warning`, so the annotation named a cause that could not have failed the
  step. Equal-precision issues are now tie-broken on severity.

## [0.1.7] - 2026-07-31

Second remediation round from end-to-end testing released `0.1.6` against the
canary repo `Azure/terraform-azurerm-avm-ptn-example-repo` (F23–F48).

Two numbering sequences collided during review, so the `F` tags below are
branch-local. Where a reviewer used the same number for a different defect, the
mapping is:

| Reviewer ID | Tag used here | Defect |
| --- | --- | --- |
| F39 | F41 | Three unanchored `::error::` annotations per failure, worst-first |
| F40 | F42 | `format` and `docs` auto-fix the CI working copy and report `pass` |

Both are fixed in this release. The F39 and F40 tags below refer to the
shell-hook guard and the empty-tier status respectively.

### Breaking

- **`avm pr-check` now fails on formatting and documentation drift.** `format`
  and `docs` previously rewrote your files in the CI working copy and reported
  `pass`, so the fix was thrown away with the runner and the defect merged. Both
  steps now check rather than fix, and report `fail` with one issue per file. A
  repository with unformatted sources or a stale `README.md` that passed on
  `0.1.6` will fail on `0.1.7`. **Action required:** run `avm pre-commit`
  locally and commit the result. `pre-commit` still auto-fixes — only `pr-check`
  gates. (F42)
- **The end-to-end check name has changed.** Fanning e2e out across a per-example
  matrix renames the check from `End-to-end tests` to
  `End-to-end tests (<example>)`, one per example. A branch protection rule that
  requires the old literal name will not error — it will simply never be
  satisfied, and pull requests will wait on a check that no longer reports.
  **Action required:** in Settings → Branches → your protection rule, remove the
  required check `End-to-end tests` and add each `End-to-end tests (<example>)`
  entry that now appears. Do this in the same change that picks up `0.1.7`.
- `avm` no longer writes result objects to the success stream. Anything that
  captured a command's output as an object needs `--passthru` to get it back.
  (F23)
- `avm test e2e --example <name>` treats an unknown name, or one carrying a
  `.e2eignore` marker, as a hard error rather than a silent skip. This is
  deliberate — it is what stops a typo in a CI matrix from quietly passing — but
  a matrix generated by hand rather than by `--list` may now fail.
- The round-robin subscription fan-out reads `TEST_SUBSCRIPTION_IDS`. Repos
  configured with only `ARM_SUBSCRIPTION_ID` still work through the preserved
  fallback path, but every parallel matrix leg then deploys into the same
  subscription and may hit quota where a sequential run did not.
- **`avm pr-check` now runs the unit test tier, and its `test` step is renamed
  to `validate`.** The step called `test` never ran a test: it routes to
  `terraform validate` / `bicep build`, reports `FilesProcessed` and carries no
  run counts, so a module whose tests were broken — or entirely absent — still
  produced an all-green gauntlet in a few seconds. The step is now named for
  what it does, and a real `unit test` step runs after it.

  Two consequences. `pr-check` gets slower by the cost of your unit tier
  (~20s on a typical module). And it can newly fail: if your unit tests were
  never actually running locally, this is the run that tells you. Both are the
  point — `pr-check` documents itself as running *every check that runs in CI*,
  and that claim was not true while the unit tier was absent. Only the unit
  tier is included, because it is the one tier that is credential-free by
  design; `integration` and `e2e` need a live subscription and stay out.
  `avm pre-commit` is unchanged and still offline. (F38)
- **A repo misconfiguration now fails the gauntlet instead of skipping it.**
  `avm pr-check` and `avm pre-commit` mapped every `AvmConfigurationException`
  to `skipped`, which does not flip the overall status. That type is thrown
  both for "this verb does not apply to this ecosystem" and for real
  misconfigurations — an unresolvable tflint or mapotf config bundle, an
  unresolvable managed-files repo id, an invalid `.avm` context override,
  `AVM_OFFLINE=1`, an invalid `AVM_MIRROR`, an unknown or `.e2eignore`d e2e
  example. Any of those inside a gauntlet step rendered as a benign green run.
  Ecosystem gates now throw the new `AvmNotSupportedException` (which derives
  from `AvmConfigurationException`, so nothing else changes), and only that
  type still skips. **Action required:** none, unless one of your repos was
  quietly misconfigured — in which case the gauntlet will now say so. The step
  fails rather than errors, so the chain still runs to the end and reports
  every problem instead of stopping at the first. (F39)
- **A test tier with no test files now reports `skipped`, not `pass`.**
  `avm test unit`, `avm test integration` and `avm test e2e` returned
  `Status: pass` with `FilesProcessed = 0` when the module shipped no
  `tests/<tier>/*.tftest.hcl` (or no runnable `examples/`). Once F38 put the
  unit tier inside `pr-check`, that rendered as `unit test -> pass` for a module
  with no tests at all — indistinguishable from a real pass, and exactly the
  vacuous-green failure mode the F33 run counts exist to prevent, one level up.
  `skipped` does not flip the overall status and the CLI still exits `0`, so a
  module with no tier is reported rather than broken. **Action required:** none,
  unless you parse `Status` from these verbs — an absent tier now yields
  `skipped`. A tier whose files exist but execute no `run` blocks still reports
  `pass`; `RunsTotal = 0` is the signal there. (F40)

### Upgrade notes

- **`tflint --init` needs an authenticated token outside the reusable workflow.**
  TFLint resolves its ruleset plugins through the GitHub releases API, which
  allows 60 unauthenticated requests per hour *per source IP*. Hosted runners
  share an egress IP, so a busy period surfaces as an intermittent, platform-
  correlated lint failure that looks like a flake rather than a rate limit.
  `.github/workflows/terraform-module.yml` and this repo's own CI now both set
  `GITHUB_TOKEN` for the 5,000/hour authenticated budget, and a workflow-contract
  test keeps the two from drifting apart again. If you self-host runners, or call
  `tflint` outside the reusable workflow, set `GITHUB_TOKEN` in that environment
  too.

### Added

- `avm test e2e --example <name>` targets a single example. It accepts either
  the folder leaf (`example-a`) or a repo-relative path (`examples/example-a`)
  and may be repeated. Omitting it keeps the existing behaviour of running every
  runnable example sequentially. A name that does not exist, or that carries a
  `.e2eignore` marker, is a hard error listing the valid names rather than a
  silent pass, so a typo in a CI matrix cannot skip a real test. (F26)
- `avm test e2e --list` emits a compact JSON array of runnable example names and
  nothing else, so a workflow can build a matrix with `fromJson()` and no
  post-processing. A module with no runnable examples emits `[]`. (F27)
- The Terraform reusable workflow fans end-to-end tests out across a per-example
  matrix with `fail-fast: false`, restoring the governance round-robin
  subscription fan-out so parallel legs do not collide on quota. The matrix is
  skipped cleanly when a module has no runnable examples.
- Every step and sub-step now carries `StartTime`, `EndTime` and a duration, both
  on the result objects and in the rendered output. (F29)
- `RUNNER_DEBUG=1` (set when a workflow is re-run with debug logging) turns
  verbose on, and verbose now cascades from the entry point to engines,
  sub-cmdlets and `Invoke-AvmProcess`. `AVM_VERBOSE=1` does the same outside
  GitHub Actions. (F30)
- `avm test unit` and `avm test integration` report `RunsTotal`, `RunsPassed` and
  `RunsFailed` alongside `FilesProcessed`, and render the tally. A file count is a
  poor coverage signal; a run count exposes an empty suite immediately. (F33)

### Changed

- All module output routes through a single writer with levels, which is GitHub
  Actions aware (`::group::`, `::error::`, `::warning::`, `::debug::`) instead of
  mixing `Write-Host`, `Write-Information` and `Write-Verbose`. (F31)
- Subprocess output is quiet by default and replayed in full at the point of
  failure. Verbose or debug streams it live; GitHub Actions wraps it in a
  collapsed `::group::` so the log is present but not noisy. Long-running
  sub-steps emit a periodic elapsed-time heartbeat so a slow deploy is
  distinguishable from a hang. (F28)
- `avm` renders one summary per invocation instead of one per emitted result
  object, and labels per-item rows with the item's own identity, so
  `avm tool list` no longer reads as six conflicting statuses for one command.
  (F25)
- `avm` no longer writes result objects to the success stream by default; pass
  `--passthru` to get them back for scripting. (F23)
- Both test tiers now invoke `terraform test` identically and render a progress
  line per test run with its duration, instead of the unit tier running silently
  and the integration tier dumping raw `-json` NDJSON on the human channel. The
  `terraform init` sub-step follows the same quiet-by-default rule as everything
  else. (F33)
- Caller-rendered progress is no longer collapsed behind a GitHub Actions
  `::group::`. Grouping exists to fold away raw child output, and a sub-step that
  supplies its own line renderer emits no raw output, so the fold hid exactly the
  curated per-run progress it was meant to reveal. (F33)

### Fixed

- The release workflow no longer fails at the point of publishing. The `build`
  task stamps the tag's whole CHANGELOG section into the staged manifest's
  `ReleaseNotes`, and the PowerShell Gallery rejects any package whose
  `ReleaseNotes` exceeds 10600 characters — 0.1.7's section is 23987, so the
  first attempt was rejected with `400 (The package is invalid)` *after* the tag
  and the GitHub Release already existed. `Get-AvmReleaseNotes.ps1` gained
  `-MaxLength`, which truncates on a line boundary from the bottom (a section
  leads with `### Breaking`, so the tail is the safe end to lose) and appends a
  link to the full notes on the GitHub Release, which has no such limit. Newlines
  are measured at their CRLF worst case, because the packer may rewrite them on
  the way into the nuspec. The `build` task then re-reads the stamped manifest
  and fails locally if the value is still over the limit, so the cap is verified
  against what actually ships rather than trusted from the generator. (F49)
- `-CheckDrift` is now genuinely read-only for `docs` and `transform`. `format`
  already checked without writing, but `terraform-docs` and `mapotf` have no
  dry-run mode, so those two engines detected drift by writing first and
  comparing hashes afterwards — leaving the caller's working copy rewritten by a
  command whose whole job is to report rather than fix. Both now snapshot the
  managed files before the tool runs and restore them from a `finally` block, so
  the tree is byte-identical even when the tool throws part-way through. On an
  ephemeral CI runner this was invisible; locally, `avm pr-check` silently
  rewrote two of the three managed-content areas. Drift detection itself is
  unchanged — the tool still runs and the changed-file list is still computed
  from real hashes. (F44)
- `avm pr-check` gates formatting and documentation instead of silently fixing
  them. `format` and `docs` had no `-CheckDrift` parameter — only `sync` and
  `transform` did — so two of the four managed-content steps could not gate at
  all. Both cmdlets gained the switch and all four steps now use it. Issues
  carry relative, forward-slashed paths, so a drifted file is annotated inline
  in the pull request. `avm pre-commit` is unchanged and still auto-fixes.
  (F42)
- A shell hook is now only a misconfiguration when it has no PowerShell
  counterpart. The guard rejected the mere presence of `setup.sh`,
  `teardown.sh`, `pre.sh` or `post.sh`, but upstream AVM governance ships both
  a `.ps1` and a `.sh` side by side — so `avm test unit`, `avm test
  integration` and `avm test e2e` threw on every governance-compliant module.
  A `.sh` only matters when there is no `.ps1` beside it, because only then
  does the hook silently never run. (F39)
- The test suite result object now carries `RunsTotal` / `RunsPassed` /
  `RunsFailed` even when a tier ships no `.tftest.hcl` files at all. That case
  previously returned `Status='pass'` with `FilesProcessed=0` and no run-count
  members, so the one shape that most needs to be conspicuous — a module with no
  tests — was the one shape indistinguishable from a real result. The tier also
  now says so on the console. (F38)
- That same empty tier now reports `Status='skipped'` rather than `pass`, in the
  suite engine and the e2e engine alike. Run counts made the gap legible on the
  object, but inside a gauntlet the rendered status is what an author reads, and
  `pass` there is indistinguishable from a real one. Fixed in the engines rather
  than the gauntlet, so `avm test unit` on its own is honest too. (F40)
- A failing `avm` command reports a clean one-line failure summary and exits
  non-zero instead of surfacing a raw `OperationStopped` stack trace pointing at
  module source. The remainder of a calling script no longer stops running, so
  cleanup lines after an `avm` call execute as written. (F24)
- The failure headline now prefers a diagnostic that carries a file position.
  A failing terraform test records a bare `test run '<name>' fail` issue ahead of
  the diagnostic naming the file, line and cause, so the console summary, the
  GitHub Actions error annotation and the terminating error message all carried
  the least useful line while the actionable one sat in the body. (F24)
- A failed command now emits exactly one GitHub Actions annotation, anchored on
  the failing file, line and column so it renders inline on the offending line in
  the PR Files-changed view. A single failing test run previously produced three
  `::error::` annotations — the positionless progress line first, the actionable
  diagnostic last — and none carried a position. Annotations are capped at ten
  per step, so a badly broken PR could push the useful ones past the cap and show
  a reviewer nothing but `run … -> fail`. Narration (the per-run progress line,
  the subprocess `FAILED:` / `TIMEOUT:` lines and the gauntlet step error line)
  is now plain text and can no longer crowd out the diagnostic. Paths are
  normalised to forward slashes and rebased on `GITHUB_WORKSPACE`, because
  GitHub only anchors repo-relative paths; a diagnostic with no position still
  produces an unanchored annotation rather than none. Console output outside
  Actions is unchanged. (F41)
- A gauntlet step that fails or errors now narrates its error message at the
  point of failure, so callers that invoke `Invoke-AvmPrCheck` or
  `Invoke-AvmPreCommit` directly (bypassing the dispatcher's renderer) get a
  diagnosis instead of a bare status.
- `terraform init` now receives the same `-test-directory` as `terraform test`.
  Init only scans the default `tests/` directory when resolving modules declared
  inside `.tftest.hcl` run blocks, so with AVM tiers under `tests/unit/` and
  `tests/integration/` a `run { module { source = "./tests/integration/setup" } }`
  helper was never installed and the tier failed immediately with
  `Module not installed`. This affected a cold checkout identically, so CI was
  hit as well as local runs, and it made the standard HashiCorp pattern for
  prerequisite infrastructure unusable. (F34)
- `terraform init` now always runs before `terraform validate` and
  `terraform test` unless `-NoInit` was passed. The previous gate on the
  existence of `.terraform/` only proved init had run at some point, against a
  possibly different set of requirements, so bumping or adding a module
  dependency was not picked up on a warm working directory. CI never saw this
  (every job is a fresh checkout); it only bit locally. `-backend=false` keeps
  the warm path cheap. (F32)
- **`avm check policy` reported `pass` without evaluating a single policy, and
  now reports `skipped`.** conftest was invoked with no namespace selector, so
  it evaluated only its default `main` namespace — and none of the 266 bundled
  APRL/AVMSEC `.rego` files declares `package main`. Zero policies ran, exit was
  0, and the step passed in ~320ms, which is about what doing nothing costs. One
  of nine `pr-check` gates had never been able to fail on any AVM module. The
  engine now counts what conftest actually evaluated, exposes it as `Evaluated`,
  and reports `skipped` with an `avm.tf.policy-not-evaluated` diagnostic when
  nothing could have been checked. `skipped` does not flip a gauntlet's overall
  status, so no module breaks; under GitHub Actions it surfaces as a single
  `::warning::`, which makes the gap visible in every run instead of invisible.
  Deliberately *not* fixed by adding `--all-namespaces`: every input accessor in
  the bundles destructures `terraform show -json` shapes, so that flag alone
  would evaluate all 260 rules against an input none of them can read and count
  every one as a success — slower, more convincing, still no gate. The second
  skip reason exists precisely to catch that state, and both reasons key off the
  parser mode used to build the argv, so they retire themselves when the
  plan-JSON input path lands. Policy enforcement is therefore still a follow-up
  slice — this release stops it claiming otherwise. (F46)

### Tests

- Mock-invocation assertions are pinned to exact counts. The original claim
  under this heading was wrong: `Should -Invoke -Times 0` is *not* vacuous on
  Pester 5, which special-cases zero as exact — that behaviour is Pester 4's,
  and the repo pins `[5.5.0,)` everywhere. The genuinely loose assertions were
  the positives: `-Times 1` without `-Exactly` means "at least once", and 15 of
  them sat in the two gauntlet suites. A double-invoke injected into
  `Invoke-AvmPrCheck` was caught by exactly one test — the F42 drift gate, the
  only one already using `-Exactly`; the eight-assertion compose test passed
  with every step invoked twice. All 15 are now `-Exactly`, and
  `Invoke-AvmTestUnit` gained the compose assertion it never had. (F43, F45)
- The `conftest` component-tier stub gained an `AVM_STUB_CONFTEST_OUTPUT` hatch,
  so the component tier proves `check policy` can go **red** end-to-end rather
  than only proving it stays quiet. The previous stub emitted `[]` and the
  fixture asserted `pass` on it — the vacuous case encoded as the expectation,
  which is how F46 survived a green suite. The real-binary integration tier had
  encoded the same false expectation against *genuine* conftest and the
  *genuine* pinned bundles, and now asserts the honest `skipped` /
  `Evaluated = 0` / `avm.tf.policy-not-evaluated` triple instead. Pinning the
  evaluated count doubles as a canary: if a future bundle re-packages into
  conftest's default namespace, that assertion fails loudly rather than the gate
  silently going quiet again. (F46)
- Anchored every negative-only assertion with a positive control. A negative
  matcher (`Should -Not -Match`, `-Not -Contain`, `-Not -Be`) passes on an empty
  or `$null` subject, and `Should -Not -Throw` passes when the operation was
  never reached — so an `It` whose only assertion is negative cannot distinguish
  "the bad thing did not happen" from "nothing happened at all". Six genuine
  holes were found by forcing each captured value to empty and seeing which
  tests still passed: the `avm doctor --json` routing test (`'' |
  ConvertFrom-Json` does not throw), the `Get-AvmVersion` PSVersion cast
  (`[version]$null` does not throw), the `avm test e2e -List` discovery surface
  (an empty array would collapse the CI matrix to zero legs), the module-version
  encoding test (a zero-byte manifest satisfied both BOM and CRLF negatives), the
  dispatcher's non-zero-exit test, and a `Write-AvmLog` verbose test that was
  worse than vacuous — it captured `-InformationVariable` for output that only
  ever reaches stream 4, so it could never fail in either direction. Each fix is
  proven load-bearing by mutating the source and confirming the new anchor
  catches. (F47)
- Pinned the `avm test e2e -List` discovery contract under GitHub Actions. The
  reusable workflow feeds that string straight to `fromJson()` to build the
  per-example e2e matrix, so a single `::group::` marker leaking onto the same
  channel collapses every e2e leg — and the F31 logging overhaul emits those
  markers only when `GITHUB_ACTIONS` is set, so no existing test ran under the
  condition that enables them. Proven decisive by mutation: an
  Actions-conditional leak is caught by this test and by **nothing else** in the
  suite (31 passed / 1 failed), where the same leak made unconditional is caught
  by four. (F47)
- Documented the output-capture discard trap and the sweep that finds it
  (Appendix L.10). `| Out-String` yields nothing when a terminating error unwinds
  the pipeline, which turns any negative matcher on the capture into a vacuous
  pass; redirect to a file instead. The sweep pattern is `\d?\*?>&1` — an earlier
  audit that grepped only `*>&1` and `6>&1` missed two live `2>&1` sites. Each of
  the four capture sites in the suite is safe for a *different* reason, so the
  reason is now recorded alongside what would break it. (F47)
- `avm check policy` now stages the module's `*.tf` / `*.tfvars` into a temporary
  directory and runs conftest there, instead of pointing `--parser hcl2 .` at the
  repository root. conftest walks every file under its working directory, so on a
  real module it hit `.gitignore` (or `.editorconfig`, or `.github/**/*.yml`),
  died in `parse configurations` **before loading a single policy**, and exited 1
  with no output. That is on every AVM repository in existence: measured on the
  integration fixture, conftest reported
  `parse config: [:1,1-2: Argument or block definition required], path: .gitignore`.
  After the fix the same fixture runs to completion and reports
  `namespaces seen: main`. Naming the Terraform files as arguments — the obvious
  alternative — does not work: conftest 0.68.2 on Windows then resolves `--policy`
  paths relative to the named input and loses the drive letter.

  The staging directory lives under the AVM cache rather than the system temp
  directory, and that is load-bearing for the same reason. conftest strips the
  drive letter from `--policy` regardless of the input form, so an absolute bundle
  path only resolves when the working directory is on the **same volume**. With
  the bundles on `C:`, staging on `C:` exits 0 and staging on `Q:` exits 1 with
  `GetFileAttributesEx \Users\…\avm-policy-aprl\…: The system cannot find the path
  specified.` The bundles live under the cache root, so staging there shares a
  volume by construction on every OS. This was latent until the parse abort above
  was fixed — that crash happens first and masked it — and it surfaced on Windows
  CI, where the checkout and `AVM_HOME` are on `D:` while the temp directory is on
  `C:`. Reproduced locally by pointing `AVM_HOME` at a second volume: the released
  arrangement reports `error` / `avm.tf.policy-run-failed` / `loading policies`,
  and the fixed one reports `namespaces seen: main`. (F48)
- `avm check policy` no longer reports a conftest crash as the F46 vacuity skip.
  conftest reuses exit 1 for *"a policy failed"* and *"I aborted before evaluating
  anything"*, and the engine only treated codes other than 0 and 1 as a
  malfunction — so a crash fell through to the normal path, produced zero records,
  and was reported with the diagnostic *"the bundles declare no rules in the
  default 'main' namespace"*. True about the bundles, false as the reason. A
  non-zero exit with no parseable output is now `Status='error'` carrying
  conftest's stderr under `avm.tf.policy-run-failed`. This outlives F46: that
  guard self-cancels once the plan-JSON slice lands, this one does not. A module
  holding no Terraform sources at all is detected before conftest is launched and
  stays a skip, because *nothing to check* is not a failure. (F48)
- Stopped the test suite ratifying the crash above. The integration and component
  tiers both asserted `Evaluated -eq 0` — a value **both** causes produce, so the
  assertions passed for the crash for as long as it existed. They now pin the
  cause (`namespaces seen: main`), which only a completed run can report. The
  component stub's default output was `[]` with a comment claiming that was what
  real conftest emits; it is not — that is the *crash* shape. The stub now
  enumerates its working directory, emits one `main`-namespace record per input,
  and reproduces the parse abort if a non-Terraform file reaches it, so the
  component tier witnesses the staging too. (F48)

## [0.1.6] - 2026-07-31

### Added

- Every `avm` status result now renders a concise command status, chain step
  status/error/duration, and issue detail on the Information stream. GitHub
  Actions runs append the same diagnostics to `GITHUB_STEP_SUMMARY`. (F20, F21)
- `Invoke-AvmProcess -StreamOutput` emits child stdout and stderr while retaining
  both captured values. Terraform init, integration tests, and e2e lifecycle
  operations and hooks enable it by default. (F21)

### Fixed

- `avm transform` removes every PATH entry containing another platform-specific
  terraform executable before exposing the resolved pinned terraform to mapotf.
  The override is scoped to the mapotf child process. (F19)
- `AvmCommandException` includes the first failing step or issue diagnostic
  instead of reporting only the aggregate status. (F20)
- The Terraform reusable workflow no longer masks the non-secret subscription
  ID before publishing it as a job output, so downstream Azure test jobs receive
  `ARM_SUBSCRIPTION_ID`. (F22)

## [0.1.5] - 2026-07-30

Remediation of the 18 defects (F01–F18) found while end-to-end testing `0.1.4`
against the canary repo `Azure/terraform-azurerm-avm-ptn-example-repo`.

### Added

- Pinned tools now **install themselves on demand**. Any gauntlet verb that
  needs `terraform`, `tflint`, `terraform-docs`, `conftest` or `mapotf` acquires
  it transparently through the existing pin manifest, SHA-verified cache and
  cross-process lock, so a clean machine or CI runner needs no `avm tool
  install` step. Set `AVM_NO_AUTO_INSTALL=1` to restore the previous hard
  failure in locked-down or air-gapped environments. (F06)
- Managed files can now **merge line sets into an existing file** instead of
  replacing it, so a consumer's own `.gitignore` additions survive a sync. A
  `.avm-managed-lines.json` in each managed-file group folder maps a
  forward-slash relative path to `{ required: [...], removed: [...] }` — lines to
  ensure present and lines to retire. Specs stack across overlays in the same
  root-then-ascending order as managed files themselves, with last-writer-wins
  per line, so canary and other groups can layer their own. A missing target
  file is created like any other managed file.
- `Resources/tflint/` ships the three governance TFLint rulesets
  (`avm.tflint.hcl`, `avm.tflint_module.hcl`, `avm.tflint_example.hcl`), and
  `Resources/mapotf/pre-commit/` ships the nine mapotf transform configs, so
  neither is resolved from outside the installed module. (F16, F03)
- `Resources/avm.pins.jsonc` is a single commented manifest holding **every**
  version pin — managed tools, the `Azure/policy-library-avm` bundle and the
  TFLint plugins — replacing the scattered `tools.lock.psd1` /
  `pinned-assets.psd1` pair. `scripts/Update-AvmPins.ps1` refreshes it in place
  while preserving comments.
- Release runs now verify the published version is actually resolvable via
  `Find-PSResource` and emit a warning annotation if gallery indexing has not
  caught up, instead of leaving consumers with a bare 404. (F14)

### Fixed

- **Repository identity is resolved from the git origin**, not the directory
  leaf name. Resolution order is explicit `-RepoId`, then
  `AVM_MANAGED_FILES_REPO_ID`, then the origin remote (HTTPS or SCP-style SSH,
  with or without `.git`, `terraform-azurerm-` / `terraform-azapi-` prefix
  stripped), then the folder leaf, then an interactive prompt, then a hard
  failure. A candidate is only accepted when it matches a governance
  `repositoryGroups` entry, and zero matching overlays is now an error rather
  than a silently successful root-only sync. This stops a worktree, fork or
  renamed clone from reverting a repo to the legacy container/make toolchain.
  (F11, F01)
- `avm` **exits non-zero** when a verb reports `Status='fail'` or
  `Status='error'`, so git hooks and CI steps can no longer pass silently. The
  reusable workflow's hand-rolled `$result.Status` wrappers have been removed
  accordingly. (F02, F18)
- `avm lint` applies the AVM TFLint rulesets. The single `--recursive`
  default-config invocation is replaced by deterministic per-scope runs — repo
  root, each `modules/*` and each `examples/*` — each initialised and linted
  with its matching config via an absolute `--config` path. (F16)
- Lint **fails on warnings** by default, which is the severity most built-in
  TFLint rules emit. Override with
  `-MinimumFailureSeverity error|warning|notice`. (F17)
- `avm transform` resolves its mapotf configs from `AVM_MPTF_CONFIG_DIR`, then
  the consumer repo's `config/mapotf/pre-commit`, then the packaged bundle. The
  previous lookup walked two levels above the installed module root and landed
  inside `PSModulePath`. (F04, F03)
- `avm check policy` works on a clean checkout. `.avm/config.json` is gone
  entirely — the module now carries immutable APRL/AVMSEC descriptors in the pin
  manifest — so the repo no longer has to satisfy a rule requiring a file that
  was simultaneously gitignored and never generated. (F07)
- `terraform.tf` is required at the Terraform repository root and in nested
  `modules/*`, but **not** under `examples/*`, so a clean canonical example repo
  passes `avm check convention`. Rule `AppliesTo` is now a normalised scope
  array rather than a single string, because the old model could not express
  this. (F08)
- Sync **never touches the git index**. Executable-mode repair mutates the
  working tree only, so a subsequent `git commit` cannot silently pick up
  unrelated staged changes. (F13)
- `avm tool list` and the engines agree on what is resolvable; PATH fallback is
  only reported where it is actually accepted. (F05)
- Engine results share a common contract — `Status`, `FilesProcessed`,
  `Changed`, `Issues` — so callers can uniformly test `$result.Status`.
  `avm format` reports a real `Status` and a real file count instead of the
  `-1` sentinel. (F15)
- `avm --help` and `avm -h` print the same help as a bare `avm`, and the
  `pre-commit` summary describes the steps it actually runs. (F09)

### Changed

- **Breaking**: the canonical rule object's `AppliesTo` is now `[string[]]`.
  `'all'` remains valid authored shorthand but is expanded at construction time;
  combining `'all'` with another scope is rejected as ambiguous.
- **Breaking**: `tools.lock.psd1` and `pinned-assets.psd1` are replaced by
  `Resources/avm.pins.jsonc`; the `*ToolsLock*` function family is replaced by
  `Read-AvmPins` / `Test-AvmPins` / `Install-AvmToolFromPins`.
- **Breaking**: `.avm/config.json` and the `avm.smoke.avm-config-exists` rule
  are removed. `.avm/` is never created by any verb and is no longer required in
  a consumer `.gitignore`; all persistent state lives under `AVM_HOME`.
- The `psgallery` release environment is documented as deliberately gate-free.
  A required reviewer there parks the run in `status=waiting` while the GitHub
  Release already looks published and the gallery 404s — the exact failure v0.1.4
  hit for ~53 minutes. (F14)

### Tests

- Regression coverage for repo-id resolution (HTTPS, HTTPS with `.git`, SSH,
  no origin, renamed worktree, folder fallback, non-interactive hard failure),
  multi-overlay stacking by ascending `managedFilesOrder` (F12), git-index
  preservation across a sync (F13), tool auto-install (cold, warm, opt-out,
  installer failure) and per-scope TFLint invocation.
- A shell-out test that invokes a failing verb through `pwsh -File` and
  `pwsh -Command` and asserts a non-zero **process** exit code, mirroring a
  `run:` step with `shell: pwsh`. (F02)

## [0.1.2] - 2026-07-30



Terraform test tiers and managed-file synchronisation.

### Added

- Tiered Terraform testing: `avm test-unit` (`Invoke-AvmTestUnit`),
  `avm test-integration` (`Invoke-AvmTestIntegration`) and `avm test-e2e`
  (`Invoke-AvmTestE2e`), backed by `Invoke-AvmTerraformTestSuite` and
  `Invoke-AvmTerraformTestE2e`.
- `avm sync` (`Invoke-AvmSync`) with the `Sync-AvmManagedFile` engine, to pull
  AVM-managed files into a module repository.
- `ConvertFrom-AvmDotEnv` for reading `.env` files used by the e2e tier.
- `.github/workflows/terraform-module.yml`: a reusable workflow that AVM
  Terraform module repositories can call for the full check + test chain.

### Changed

- `Invoke-AvmPreCommit` and `Invoke-AvmPrCheck` updated to compose the new
  test tiers.

## [0.1.1] - 2026-06-23

Release-pipeline and packaging fixes.

### Changed

- Release workflow made idempotent and re-runnable: it now creates the GitHub
  Release only when the tag has none, and otherwise re-uploads artefacts with
  `--clobber` instead of failing with "a release with the same tag name
  already exists".
- PowerShell Gallery description rewritten to describe the shipped Terraform
  chain and the managed-tool resolver rather than the Phase 0 roadmap.
- Workflow, job and step display names polished for readability.

### Added

- `-SkipIfAlreadyPublished` handling in `scripts/Publish-AvmAuthoring.ps1` so a
  re-run against an already-published version is a no-op rather than an error.

## [0.1.0] - 2026-05-18

First real release of `Avm.Authoring` — the Phase 0 skeleton from the
[consolidation plan](docs/avm-consolidation-plan.md) and
[implementation spec](docs/avm-implementation-spec.md). Single `avm`
dispatcher, managed-tool resolver, and Bicep / Terraform inner-loop
scaffolding (`format` / `lint` / `test` / `docs`).

### Added

- `avm` dispatcher (`Invoke-Avm` + `avm` alias) with kebab-case flag → PascalCase parameter coercion, bare-call help, and unknown-verb errors.
- `avm version` (`Get-AvmVersion`) and `avm doctor` (`Invoke-AvmDoctor`) with cross-platform writable-folder probes.
- Managed-tool resolver: `Get-AvmTool`, `Install-AvmTool`, `avm tool list|which|install`, backed by `tools.lock.psd1` (bicep 0.30.3, terraform 1.9.5, terraform-docs 0.18.0, tflint 0.53.0 across all six OS/arch platforms).
- `avm doctor --install` to atomically pre-fetch every managed tool with `AVM1012` skip semantics, `-Force` reinstall, and per-tool `Install-AvmToolFromLock`.
- Cross-OS folder layout (`Get-AvmFolder`) covering Config / Cache / Data / State / Tools / Logs / Temp with `AVM_HOME` override, XDG Base Directory on Linux, Windows Known Folders, and Apple Application Support layout on macOS.
- HTTP layer (`Invoke-AvmHttp`) with TLS 1.2/1.3, mandatory SHA256 verification, `AVM_OFFLINE` gate, `file://` fixture support, partial-file cleanup on hash mismatch, and `AVM_MIRROR` host rewriting via the pure `Resolve-AvmMirrorUrl` helper (preserves mirror path prefix; rejects non-https mirrors with `AvmConfigurationException`).
- Subprocess layer (`Invoke-AvmProcess`): argv-array invocation only (no shell), stdout/stderr split, timeout with process termination, `EnvVars` override, optional `IgnoreExitCode`.
- Exception hierarchy (`AvmException` / `AvmConfigurationException` / `AvmToolException` / `AvmProcessException` / `AvmContextException`) with stable error codes (`AVM1001`, `AVM1010`, `AVM1012`, `AVM1014`, `AVM1020`, `AVM1030`).
- Module context discovery (`Get-AvmModuleContext`) for Bicep monorepos, Bicep modules, Terraform module repos, and Terraform module paths, with `.avm/context.psd1` override and `-Ecosystem` filter.
- `.avm/.disable` sentinel — the dispatcher refuses to run when present.
- Bicep inner loop: `Invoke-AvmFormat` (`bicep format`), `Invoke-AvmLint` (`bicep lint --diagnostics-format defaultV2`), `Invoke-AvmTest` (`bicep build --stdout`). `Invoke-AvmDocs` throws a clear `AvmConfigurationException` until the ARM-JSON walker lands.
- Terraform inner loop: `Format-AvmTerraformModule` (`terraform fmt`), `Invoke-AvmTerraformLint` (`tflint`), `Invoke-AvmTerraformTest` (`terraform init && terraform validate`), `Invoke-AvmTerraformDocs` (`terraform-docs`).
- `Invoke-AvmPreCommit` composition (`format` → `lint` → `test` → `docs`, fail-soft by default, `-StopOnFail` for early exit).
- Build + CI: `./build.ps1` entry forwarding to Invoke-Build with `layout` / `lint` / `test` / `coverage` / `build` / `clean` / `pre-commit` / `ci` tasks; cross-platform CI on ubuntu, windows, macos.
- Spec §18 70% line-coverage floor enforced as a hard build gate in the `coverage` task; CI now runs `layout + lint + coverage`.
- Encoding/EOL guard (`tests/Pester/Unit/Module/Encoding.Tests.ps1`): rejects UTF-8 BOMs and CRLF line endings across every text file under `src/` on every `pre-commit` run.
- Layout guard (`Test-AvmModuleLayout`) with on-disk casing checks for the `Avm.Authoring/` folder and `Avm.Authoring.psd1` manifest filename, plus `PowerShellVersion >= 7.4`.
- `scripts/Publish-AvmAuthoring.ps1` (PSGallery publish with hard casing guards and `-WhatIf`) and `scripts/Update-AvmToolsLock.ps1` (refresh managed-tool SHA256s).
- Backward-compatibility shim `Get-AvmAuthoringPlaceholder` retained from `0.0.1`.

### Tests

- 230 Pester unit tests across `tests/Pester/Unit/{Module,Public,Private,Private/Engines}/`; 2 platform-conditional skips on non-host OSes.
- Aggregate line coverage 78.83% (1,013 of 1,285 commands across 30 files) — well above the 70% floor.

## [0.0.1] - 2026-05-12

Initial placeholder release to reserve the `Avm.Authoring` package name on
PowerShell Gallery. Exposed only the `Get-AvmAuthoringPlaceholder` cmdlet
so callers could verify the module loads end-to-end.

[Unreleased]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Azure/azure-verified-modules-tools/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/Azure/azure-verified-modules-tools/releases/tag/v0.0.1
