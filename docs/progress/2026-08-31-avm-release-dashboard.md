# Publish an AVM Terraform release-status dashboard

**Status**: in-progress
**Started**: 2026-08-31
**Updated**: 2026-08-31
**Branch**: `myaschmitz-avm-release-dashboard`

## Outcome

A static page at `https://azure.github.io/azure-verified-modules-tools/` reporting, for every non-archived `Azure/terraform-azurerm-avm-*` repository, whether merged work is missing from the newest published version.

The gap is invisible from any single repository. The Terraform registry publishes from git tags, so a fix can sit on `main` for months while consumers still install the older tagged version. Nothing measured that. A sweep of all 188 repositories found 38 carrying human commits past their newest tag, holding 96 merged pull requests between them, with a median wait of 165 days and a worst case of 878.

Prototyped and proven at [`myaschmitz/avm-release-dashboard`](https://github.com/myaschmitz/avm-release-dashboard), which has now published on schedule for four consecutive days. This slice moves that work into `repository-management/`, beside the sync and creation tooling it belongs with.

## Design decisions and the evidence behind them

**Tags, not releases.** `/releases/latest` sorts by creation rather than by version, so `netapp-netappaccount` reported `0.2.0` while `v0.3.0` existed. Three repositories — `aks-economy`, `aks-enterprise`, `certificateregistration-certificateorder` — carry a version tag with no GitHub release at all, and reading releases alone reports those as never published while the registry serves them. `Get-NewestVersion` therefore reads tags and falls back to the tagged commit's date when no release carries one.

**Author, not commit message.** The AVM bot pushes `chore: run avm pre-commit [skip ci]` to every repository one to three times a day, so almost every default branch is ahead of its newest tag. Subjects such as `fix: grept apply` appear under both bot and human authorship, so no subject pattern separates them. The test is `-notmatch '\[bot\]$'` rather than `-like '*[bot]'`, because `-like` reads `[bot]` as a character class: it matches any login ending in `b`, `o` or `t`, never the literal suffix, and silently counts every bot as human. That bug alone moved the headline count from 36 to 138 before it was caught.

**Pull requests come from the commit subject.** A squash merge creates a new commit, so the `merge_commit_sha` recorded on a pull request is frequently not the commit that reached the default branch — observed on `netapp-netappaccount`, where PR #31's recorded SHA is absent from `main` and the work landed under PR #32's commit. The trailing `(#123)` that squashing writes into the subject survives. Extraction matched 38 of 38 repositories with unreleased work, with no misses.

**No suggested version.** SNFR17 requires a minor bump for a breaking change or a feature and a patch bump for a backward-compatible fix. Deciding that from commit subjects fails: a computed bump matched history in only 5 of 10 cases tested, and 25 of 90 unreleased pull requests carry no conventional-commit prefix at all. Comparing the module's declared interface instead — every `variable` and `output` at the tag against the default branch — matched 8 of 10, and both disagreements were cases where a maintainer added a variable and shipped it as a patch, which SNFR17 calls a minor bump. Against the specification the comparison is right in all ten. The page therefore shows a suggested version beside the evidence that produced it, and links to GitHub's new-release page with the tag left blank.

Two details carry that result. Descriptions are excluded from the comparison, because AVM descriptions are long and change on their own schedule, so a documentation edit would otherwise read as an interface change. And the parser counts brace depth rather than splitting on a regex, because those same descriptions embed worked Terraform examples containing `variable "foo"`, which a naive split counts as a real declaration.

Removing a declaration, or adding a variable with no `default`, is marked breaking. That distinction only changes the suggested version at 1.0.0 and above, where a breaking change bumps the major. Not every AVM module is pre-1.0 — `avm-res-web-hostingenvironment` is already at 2.0.1 — so the version selects the rule rather than the rule being assumed.

**Ranking each altered declaration, and the false positive that ranking first produced.** Comparing whole declarations said only that something moved, which left a maintainer to open the diff to learn what. Splitting each one into `type`, `default`, `nullable`, `sensitive`, `value` and its validation rules produces four verdicts: `breaking`, `behaviour`, `relaxed`, and `unclear` for whatever a comparison cannot rank. Of 79 field-level changes measured across the modules waiting on a release, 64 ranked and 15 did not — 13 object types whose attributes moved and 2 rewritten validation rules.

The first version of that ranking judged each field alone, and was wrong. On `avm-res-storage-storageaccount`, `private_endpoints.subresource_name` moved from `string` to `optional(string, null)` while a new validation rule required it to be non-null. Those cancel: the same input is accepted as before, and only the error message differs. The classifier saw `validationCount 0 -> 1`, asserted "breaks callers", separately marked the type change "needs reading", and never connected them. Three declarations were affected — `private_endpoints` here, `os_disk` on the virtual machine, and `compute_gallery_image_definitions` on the image builder — and the count of modules asserted breaking fell from 11 to 9 once fixed. A validation rule added while the type is unchanged is still breaking, because nothing can be compensating for it.

A false "breaks callers" is worse than an honest "needs reading". The first is acted on, the second is checked.

**History is committed; the snapshot is not.** `release-status.json` is rebuilt from the API on every run and reproduces exactly, so it is gitignored. `history.json` cannot be rebuilt, because the API reports only the present. The workflow commits it back with `GITHUB_TOKEN`, which does not trigger new runs, and the `push` trigger lists only hand-edited paths because a workflow may not combine `paths` with `paths-ignore`.

## Checklist

- [x] Add `repository-management/release-dashboard/scripts/Get-AvmReleaseStatus.ps1`.
- [x] Add `repository-management/release-dashboard/scripts/Update-AvmReleaseHistory.ps1`.
- [x] Add the static site under `repository-management/release-dashboard/site/`.
- [x] Add `.github/workflows/repository-management-dashboard.yml`, following the `repository-management-*` naming already in use.
- [x] Gitignore the derived snapshot, commit the history.
- [x] Document the decisions in `repository-management/release-dashboard/README.md`.
- [x] Suggest the next version by comparing the declared interface at the tag against the default branch.
- [x] Rank each altered declaration field by field, so the page names what a change means for callers.
- [ ] Repository admin enables Pages once (see below).

## Blockers and dependencies

**Pages must be enabled by an admin before the first run can publish.** `GITHUB_TOKEN` cannot call the create-Pages-site endpoint. `actions/configure-pages` with `enablement: true` was tried first and failed with `HttpError: Resource not accessible by integration`, so the workflow no longer asks. A repository admin runs this once:

```pwsh
gh api -X POST repos/Azure/azure-verified-modules-tools/pages -f build_type=workflow
```

Until then the collector, the history step and the artifact upload all succeed, and only `deploy-pages` fails.

## Validation

- Four consecutive scheduled runs on the prototype repository, 28 to 31 August, each publishing successfully.
- API budget measured on the runner before and after each sweep: `core limit=5000 remaining=5000`. The sweep issues roughly 900 calls across 188 repositories in about six minutes, so the hourly allowance is not a constraint.
- Live output verified field by field against the GitHub API: 188 repositories, 38 with unreleased work, 96 unreleased pull requests, 5 issues labelled `Status: Awaiting Release To Be Cut :scissors:`, and no null `latestTag` on any repository not classified `never-released`.
- Version suggestion scored against ten historical bumps across five repositories: 8 of 10 agree with what shipped, 10 of 10 agree with SNFR17. Both breaking calls in today's data are corroborated by the pull request titles that produced them — `avm-res-web-site` removed three outputs under `fix!: remove unused whole-resource outputs`, and `avm-res-compute-virtualmachine` renamed `enable_automatic_updates` to `automatic_updates_enabled`.
- The block parser was cross-checked against a naive top-level regex on four repositories and agreed on every count, confirming the brace walker does not miss or invent declarations.
- Field-level verdicts spot-checked against the repositories that produced them. `avm-res-web-site` drops `sensitive = true` from four outputs, which is PR #371, titled `fix!: correct sensitivity markers on site outputs`. `avm-ptn-aks-economy` adds `nullable = false` to `enable_telemetry`, so configurations passing null now fail. Both were found without reading a commit message.
- `./build.ps1 pre-commit`: layout, lint and unit legs green. The component leg reports the same two pre-existing failures on this branch and on a clean `main` — `pr-check composes eight steps` and `pr-check rejects a shell hook`, both raising `AvmToolException: Tool 'tflint' does not ship a release for 'windows-arm64'`. That is an authoring-machine architecture limit, not a regression; this slice adds no files under `src/` or `tests/`.
