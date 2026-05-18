# Agent instructions

This repo is being delivered phase by phase against the plan in [`docs/avm-consolidation-plan.md`](docs/avm-consolidation-plan.md) and the engineering rules in [`docs/avm-implementation-spec.md`](docs/avm-implementation-spec.md). Sessions get swapped out often, so the work depends on every agent leaving the next agent a clean handoff.

## Read first, in this order

1. **[`docs/progress.md`](docs/progress.md)** — the living checklist. Tells you what's done, what's in flight (`[~]`), what's blocked, and what to pick up next. **Always start here.**
2. **[`docs/avm-implementation-spec.md`](docs/avm-implementation-spec.md)** — wins on implementation details (file layout, encoding, cross-OS rules, error handling, testing layers).
3. **[`docs/avm-consolidation-plan.md`](docs/avm-consolidation-plan.md)** — wins on scope and sequencing (verb table, phase exit criteria, architecture options).
4. **[`docs/avm-tooling-report.md`](docs/avm-tooling-report.md)** — inventory of the existing AVM tooling being consolidated; useful when porting a legacy script.

## Working protocol

The protocol exists so that "I lost my context window" never means "I lost my place."

- **Before starting a slice**, flip its checkbox in `docs/progress.md` from `[ ]` to `[~]` so the next session knows it's in flight.
- **When you finish a slice**, flip `[~]` to `[x]`. Add a one-line note only if there's something a future reader would otherwise be surprised by (a workaround, a deferred sub-task, the commit hash).
- **When you discover a new must-do**, add it under the right phase. Don't reshape historical items — they're the audit trail.
- **When you hit a blocker** you can't unstick this turn, capture it under **Known issues** at the top of `docs/progress.md` with a one-line diagnosis and a candidate fix. Leave the original checkbox in `[~]`.
- **Always** bump the `Last updated` line at the top of `docs/progress.md` when you change the file.
- **Never delete completed items.**
- **Commit and push after every meaningful change.** As soon as `./build.ps1 pre-commit` is green for a slice (or for a focused doc-only edit that doesn't need it), stage the change, write a Conventional-Commits message, commit, and `git push` to the active feature branch. The user explicitly opted in to this on 2026-05-18 — they want each slice landed on `origin` as it completes so a lost session never costs more than the last unpushed slice. See **Commit & push protocol** below for the exact rules.

## Commit & push protocol

- **Cadence**: one commit per slice. A "slice" is the unit you just flipped from `[~]` to `[x]` in `docs/progress.md` (or a self-contained doc/refactor that doesn't have its own checkbox).
- **Gate**: `./build.ps1 pre-commit` must be green before you commit code changes. Doc-only commits skip the gate.
- **Message style**: Conventional Commits.
  - `feat(<area>): …` for new behaviour (`feat(http): honour AVM_MIRROR via Resolve-AvmMirrorUrl helper`).
  - `fix(<area>): …` for bug fixes.
  - `refactor(<area>): …`, `test(<area>): …`, `docs: …`, `chore: …`, `ci: …` as appropriate.
  - First line ≤ 72 chars. Use a body when the *why* isn't obvious from the diff; reference the spec / progress item.
- **Staging**: prefer `git add -A` for slice commits so progress-doc updates land with the code. If you have unrelated dirty files (rare), be explicit instead.
- **Push**: `git push origin <branch>` immediately after the commit. Never `--force`. Never push to `main`.
- **Failure path**: if `git push` is rejected because the remote moved, `git pull --rebase origin <branch>` and re-run `./build.ps1 pre-commit` before retrying the push. Do not force-push to resolve.
- **PRs / merges**: still user-driven. Don't open, merge, or close PRs without explicit instruction.

## Build / test commands

```pwsh
./build.ps1 layout       # casing & manifest guards (fast)
./build.ps1 lint         # PSScriptAnalyzer + repo settings
./build.ps1 test         # Pester unit tests (excludes Smoke + Integration)
./build.ps1 pre-commit   # layout + lint + test (the recommended local gate)
./build.ps1 ci           # CI entry point (alias for pre-commit, called from .github/workflows/ci.yml)
./build.ps1 coverage     # Pester with coverage (JaCoCo XML under out/coverage/)
./build.ps1 clean        # remove out/
```

Run `./build.ps1 pre-commit` before handing work off. If lint ever crashes with `Object reference not set to an instance of an object.`, see `docs/progress.md` Known issues — the prior recurrence was transient and bisecting per file under `src/Avm.Authoring/` was the diagnostic path.

## Repo conventions that matter

- **PowerShell 7.4+, Core only.** No Windows PowerShell 5.1 paths.
- **LF, UTF-8 (no BOM)** for every text file in `src/`. `.gitattributes` enforces it; if a `git status` shows CRLF warnings, fix the file rather than fighting `core.autocrlf`.
- **Approved verbs only.** `Get-Verb` is the allow-list.
- **`Avm` prefix** on every exported function and noun.
- **Argv-array subprocess invocation** through `Invoke-AvmProcess`. Never build a single command string.
- **`[CmdletBinding(SupportsShouldProcess)]`** on any cmdlet that writes to disk or state.
- **Spec §6 casing rules**: the `Avm.Authoring/` folder and `Avm.Authoring.psd1` filename are guarded by `Test-AvmModuleLayout` after a 2026-05 manifest-casing incident. Don't loosen those guards.

## Known traps

Read [`/memories/repo/pester-and-lint-gotchas.md`](.) (in your assistant's memory store, not in the repo) before you fight PSScriptAnalyzer or Pester 5 scoping. It captures the recurring failure modes:

- `PSUseConsistentWhitespace` + `PSAlignAssignmentStatement` mutual exclusion
- `PSUseProcessBlockForPipelineCommand` requiring `begin {}` around `Set-StrictMode` when the function has `[Parameter(ValueFromPipeline)]`
- Auto-variable traps (`$matches`, `$eventArgs`) inside Pester `It` blocks
- `function script:Foo { … }` nested inside another function occasionally crashing PSScriptAnalyzer with `NullReferenceException` (suspected cause of a transient crash seen in 2026-05; no longer reproducing)
- Pester 5 `TestCases` parameter binding (`<word>` placeholders) accidentally hitting test names

## Branch & PR posture

- **Active branch**: `feat/avm-authoring-initial` (pushed to `origin`).
- **Default branch**: `main`, which currently has only the initial commit.
- Commit-and-push to the active feature branch after every slice (see **Commit & push protocol**). Never push to `main`. Never force-push. Never open, merge, or close a PR without explicit user instruction.
