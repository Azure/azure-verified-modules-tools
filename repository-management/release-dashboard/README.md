# Release dashboard

A static page showing where each AVM Terraform module's published version sits relative to its default branch. Published to GitHub Pages by [`repository-management-dashboard.yml`](../../.github/workflows/repository-management-dashboard.yml).

## Why it exists

A module can be fixed on `main` and still be unavailable to anyone consuming it, because the Terraform registry publishes from git tags rather than from branch state. The gap is invisible from any single repository. This page reports it across all of them: which modules carry merged work that no tag includes, which pull requests are inside that work, and how long each has waited.

## What it reports

For every non-archived `Azure/terraform-azurerm-avm-*` repository:

| Field | Source |
| --- | --- |
| Newest version | highest semver git tag |
| Published | the release for that tag, else the tagged commit's date |
| Unreleased commits | commits on the default branch past that tag, authored by a person |
| Oldest days | age of the oldest such commit |
| Managed files | `version` in `.avm/managed-files-version.json` |

Rows with unreleased pull requests or issues labelled `Status: Awaiting Release To Be Cut :scissors:` expand to list them.

## Decisions worth knowing

**Tags, not releases.** The registry serves tags. Three repositories carry a version tag with no GitHub release at all, and `/releases/latest` can return a stale tag because it sorts by creation rather than by version. Reading releases alone misreports both cases.

**Author, not commit message.** The AVM bot pushes `chore: run avm pre-commit` to every repository daily, so nearly every default branch is ahead of its newest tag. Subjects such as `fix: grept apply` appear under both bot and human authorship, so only the author separates real work from automation. The test is a regex, because PowerShell's `-like` reads `[bot]` as a character class and never matches the literal suffix.

**Pull requests come from the commit subject.** A squash merge writes `(#123)` into the subject and creates a new commit, so the `merge_commit_sha` recorded on a pull request is often not the commit that reached the default branch. The subject is the reliable link back.

**No suggested version.** SNFR17 requires a minor bump for a breaking change or a feature and a patch bump for a backward-compatible fix. Deciding that from commit subjects fails: a computed bump matched history in only 5 of 10 cases tested, and 25 of 90 unreleased pull requests carry no conventional-commit prefix at all. The page links to GitHub's new-release page with the tag left blank.

## Data files

`site/data/release-status.json` is rebuilt from the API on every run and is **not** committed. Run the collector before serving locally.

`site/data/history.json` **is** committed. It holds one row per day, and the API only reports the present, so a day that goes unrecorded cannot be recovered. The workflow commits it back using `GITHUB_TOKEN`, which does not trigger new runs.

## Running it locally

```pwsh
cd repository-management/release-dashboard
pwsh -File scripts/Get-AvmReleaseStatus.ps1 -OutputPath site/data/release-status.json
pwsh -File scripts/Update-AvmReleaseHistory.ps1
node site/serve.js
```

A full sweep covers 188 repositories in about six minutes and roughly 900 API calls, well inside the 5,000 per hour that `GITHUB_TOKEN` allows. Use `-MaxRepos 10` for a fast pass while working on the page itself.

## Enabling Pages

`GITHUB_TOKEN` cannot create a Pages site, so `actions/configure-pages` fails with `Resource not accessible by integration` until a repository admin runs this once:

```pwsh
gh api -X POST repos/Azure/azure-verified-modules-tools/pages -f build_type=workflow
```

The site then publishes to `https://azure.github.io/azure-verified-modules-tools/`.
