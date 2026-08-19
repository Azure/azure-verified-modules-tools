# Terraform spell check

**Status**: complete
**Started**: 2026-08-18
**Updated**: 2026-08-18
**Branch**: `myaschmitz-terraform-spell-check`

## Outcome

Add `avm check spelling` for Terraform modules, backed by a pinned `typos` binary and a vendored AVM allowlist, and wire it into `pre-commit` and `pr-check` at warning severity. Closes the gap in [#69](https://github.com/Azure/azure-verified-modules-tools/issues/69): a typo in a `variable`/`output` description propagates into the generated `README.md`, and contributors who notice it later patch the README, which the next `terraform-docs` run reverts.

## Design decisions

**Scan the source, not the artifact.** `README.md` in an AVM module is entirely `terraform-docs` output between `BEGIN_TF_DOCS` and `END_TF_DOCS`. A fix applied there does not survive regeneration — verified by hand-fixing `criterias` out of `avm-res-cdn-profile`'s README (7 occurrences to 0), running `terraform-docs -c .terraform-docs.yml .`, and getting all 7 back with an empty `git diff`. The engine skips any `README.md` whose first 40 lines contain `BEGIN_TF_DOCS`, so findings always land on the file where a fix persists. Detection is marker-based rather than filename-based, so a hand-written README is still scanned.

**Report only; never `--write-changes`.** Auto-fix rewrites identifiers, not just prose. On `avm-res-cdn-profile` it rewrote `module "criterias_alert"` to `module "criteria_alert"` while leaving the same token in a `source = "Azure/avm-res-criterias-something/azurerm"` line — an inconsistent, desynchronised tree, and for a published module a silent breaking change to the variable interface.

**Allowlist over agent.** `typos` is not a dictionary checker; it matches a fixed corpus of ~100k known misspellings. Unknown identifiers (`azurerm`, `mptf`, `tfvars`, `privatelink`) can never be flagged. The entire false-positive surface is short Azure acronyms that collide with real English typos, which is small, enumerable, and fixed — so a static allowlist covers it and an AI reviewer is unnecessary.

## Allowlist derivation

Scanned all 188 active, non-archived `Azure/terraform-azurerm-avm-*` repositories with `typos` 1.49.0.

| | Before allowlist | After |
| --- | --- | --- |
| Total hits | 2,259 | 414 |
| Unique words | 122 | 104 |
| Repos with any finding | 188 | 56 |

Classification heuristic: false positives are high-volume and spread across many repos (`caf`: 823 hits across 147 repos); real typos are low-volume and confined to one repo (`througput`: 36 hits, 1 repo). Repo spread ranks the candidates; every entry was then confirmed by reading its source line.

The vendored list is `src/Avm.Authoring/Resources/typos/avm.typos.toml`: 14 `extend-words` plus three `extend-exclude` globs for binary-ish document formats (`*.rtf`, `*.docx`, `*.pdf`) whose internal markup produced noise like `\fswiss\fcharset0` matching `ba`, `agre`, and `ure`.

**Known cost.** An allowlist entry is all-or-nothing per word: it removes the term from the corpus before scanning, so a genuine `sent` typed as `snet` is silently missed. Verified — with `snet` allowlisted, two real `sent`-to-`snet` typos produce `exit=0`. Four entries carry that cost (`snet`, `aks`, `anf`, `ot`); the rest (`caf`, `hdinsight`, `yor`, `ful`, `bse`, `nore`) shadow nothing anyone would type. Accepted, because coverage today is zero and a checker with a 60% false-positive rate gets ignored, which is a 100% false-negative rate in practice.

**Deliberately not allowlisted**, because they are real typos that belong in a repo-local `.typos.toml` rather than the shared vocabulary: `criterias` (51 hits — baked into `avm-res-cdn-profile`'s published variable interface, so fixing it is a breaking change), `nam`, `asser`, `ands`, `mis`.

## Config merge

The engine passes `--config <vendored>` and deliberately omits `--isolated`. `typos` **merges** a `--config` file with any `.typos.toml` discovered in the scanned tree rather than overriding it — verified bidirectionally: a central file allowing `aks` plus a repo file allowing `criterias` reported only the planted `teh`. That is what lets an individual module record a local term without losing the shared vocabulary.

## Severity ramp

Both gauntlets run the step at `Severity = 'warning'`, so findings are printed but `Status` stays `pass`. Promote to `error` once the estate is clean; 132 of 188 repos already pass with the allowlist applied.

## Checklist

- [x] Pin `typos` 1.49.0 in `avm.pins.jsonc` with SHA-256 for all five shipped platforms.
- [x] Vendor `Resources/typos/avm.typos.toml` with the derived allowlist.
- [x] Add `Engines/Terraform/Invoke-AvmTerraformCheckSpelling.ps1`.
- [x] Add `Public/Invoke-AvmCheckSpelling.ps1` and register `check spelling` in the verb registry and manifest.
- [x] Wire the step into `Invoke-AvmPreCommit` and `Invoke-AvmPrCheck` at warning severity.
- [x] Pester unit coverage for the parser, generated-README filter, config resolution, unsupported-platform mapping, and dispatcher registration.
- [x] Component coverage for the clean path, the red path, and the generated-README skip, driven by a `tests/fixtures/bin/typos.ps1` stub.
- [x] `./build.ps1 pre-commit`.

## Validation

- `./build.ps1 pre-commit`: layout, lint, and unit tests green. Component tests leave 2 failures on this Windows ARM64 host, which is the exact pre-existing baseline (both are `tflint`/`AVM1012`, confirmed by re-running the suite on a stashed tree). Re-running with the `windows-arm64` guard temporarily lifted so the stub launcher is reachable gives 36 passed / 0 spelling failures.
- Smoke test against a fixture: caught `Requries` in `variables.tf` and `recieve` in a hand-written `CONTRIBUTING.md`; skipped `Requries`/`virutal` inside a `BEGIN_TF_DOCS` README; did not flag allowlisted `AKS` or `snet`. `-Severity error` flipped `Status` to `fail`; a clean tree returned `pass` with zero issues; `avm check spelling` routed and rendered correctly.

## Unsupported platforms degrade to skip

Upstream ships no `aarch64-pc-windows-msvc` asset, so `windows-arm64` is in `unsupportedPlatforms` and `Resolve-AvmTool` throws `AVM1012` — the same gap `tflint` already has. `tflint` only affects `pr-check`, but spelling runs in `pre-commit`, so letting `AVM1012` propagate would make the whole local gauntlet unusable on Windows ARM rather than degrading one step.

The engine therefore maps `AVM1012` (and only `AVM1012`) to `AvmNotSupportedException`, which the gauntlet already renders as a visible `skipped` step carrying the reason. Every other `AvmToolException` — a SHA-256 mismatch, for instance — still propagates. Coverage is unaffected: CI runs on a supported platform.

The three direct-call component tests carry `-Skip:$script:typosUnsupported`, evaluated at discovery time because `-Skip:` on `It` binds before any `BeforeAll` runs.
