# Module owner audit

[`Invoke-AvmModuleOwnerAudit.ps1`](scripts/Invoke-AvmModuleOwnerAudit.ps1)
checks that every owner of every AVM root module is still an active Microsoft
FTE. It reports modules that would be orphaned or lose owners, and reconciles
open "Orphaned Module" issues. It can optionally remediate both ecosystems
through pull requests and issues.

This is an operator tool for the AVM core team. It is not run on a schedule
and has no workflow. The default mode is report-only.

## How owners are classified

The audit reads the published catalog
(`Azure/Azure-Verified-Modules` `docs/static/module-indexes/v1/modules.json` on
`main`) using the same integrity-verified reader as
[reviewer routing](../reviewer-routing/). It audits only root modules: child
modules inherit owners and must not declare them.

| Owner status | Meaning | Action |
| --- | --- | --- |
| `Active` | Member of the `Azure` org and the `azure-verified-modules-module-contributors` team | Keep |
| `ActiveNotInTeam` | Member of the `Azure` org but not the team | Keep. Ask the owner to join the [access package](https://aka.ms/avm/id/access-package/module-contributor) |
| `NotInOrg` | GitHub account exists but is not in the `Azure` org | Remove |
| `AccountNotFound` | GitHub account deleted or renamed | Remove |
| `Exempt` | Listed in `-ExemptHandles` or `-ExemptHandlesPath` | Keep |

`Azure` org membership requires a Microsoft identity linked through the Open
Source Portal, so the audit uses it as the FTE signal. A removed owner who is
still an FTE can rejoin the org and the team, and then be re-added.

## Verdicts

Each root module gets one verdict. They are listed below in priority order.
Proposed modules are reported in their own section and are never changed.
Deprecated modules are used only to check issue hygiene.

| Verdict | Condition | `-Apply` action |
| --- | --- | --- |
| `WouldOrphan` | Available module with no active owner left | Set `owners` to `[]`, then raise or reuse an orphaned module issue |
| `OrphanMissingIssue` | Orphaned module with no open orphaned module issue | Raise an issue |
| `OwnerReduction` | Inactive owners present, at least one active owner remains | Remove the inactive owners |
| `OrphanIssueCanClose` | Open orphan issue, but the module is Available. Every owner is `Active` and the live root `metadata.json` has owners | With `-CloseResolvedIssues`: post the standard closing remarks, relabel and close the issue |
| `OrphanIssueNeedsReview` | Open orphan issue and the module has owners, but auto-close conditions are not met | None |
| `NeedsTeamJoin` | All owners active, at least one is `ActiveNotInTeam` | None (contact the owner) |
| `IssueHygiene` | Open orphan issue that is unmatched, duplicated, or for a deprecated or proposed module | None |
| `OK` | Nothing to do. Includes orphaned modules that already have an open issue | None |

Open issues labelled `Status: Module Orphaned 🟡` are matched to modules using
the title, the issue form's "Module Name" field, module names, Terraform
repository names, and registry or repository URLs in the body. Bicep child
modules map to their root module. Closed issues are never reused, because a
module that becomes orphaned again needs a new issue.

## Usage

The script needs PowerShell 7.4+ and `gh` authenticated as an `Azure` org
member with the `repo`, `read:org` and `project` scopes. Import Avm.Authoring
first. `-Apply` needs version 0.20.0 or later, or this repository's `src` build.

```pwsh
Import-Module ./src/Avm.Authoring/Avm.Authoring.psd1
./repository-management/module-owner-audit/scripts/Invoke-AvmModuleOwnerAudit.ps1
```

A full run makes around 150 GitHub API calls and takes about 80 seconds. It
prints the report, then writes two CSVs and a run log to `-OutputPath`
(default: `<temp>/avm-owner-audit`):

- `*-modules.csv`: one row per module
- `*-owners.csv`: one row per module owner, with the action to take

The terminal report shows a verdict matrix by language and module type
(`Bicep-Res` … `TF-Utl`). It then lists each verdict grouped under
`-- <Language> / <Type>` headers, followed by the owners to contact and the
proposed modules.

| Parameter | Purpose |
| --- | --- |
| `-Ecosystem bicep, terraform` | Limit by language |
| `-ModuleType resource, pattern, utility` | Limit by module type |
| `-ModuleFilter 'avm/res/network/*'` | Limit by module name, path or repository wildcard |
| `-ExemptHandles`, `-ExemptHandlesPath` | Never treat these handles as inactive |
| `-Apply` | Make changes. Each change asks for confirmation unless `-Force` is set. `-WhatIf` previews |
| `-MaxChanges n` | Cap module-level changes |
| `-CloseResolvedIssues` | Also close `OrphanIssueCanClose` issues |
| `-TargetRepoOverride`, `-IssueRepoOverride` | Test against a sandbox repository. Both must be set together |

## What `-Apply` changes

1. Before editing, it re-reads the live root `metadata.json` on the default
   branch. It replaces only the text of the `owners` array, keeping the rest
   of the formatting, and validates the result with `Test-AvmModuleMetadata`.
2. For orphaned modules it creates the issue first, using the
   `5_orphaned_module.yml` form fields and labels, or reuses an open one. It
   adds the issue to projects 529 (`Status: Orphaned`) and 1011
   (`Status: Needs: Triage`).
3. It pushes an `avm-owner-audit/<yyyyMMdd>` branch directly to each
   repository and opens one pull request per repository. That means one batch
   PR for `Azure/bicep-registry-modules` and one PR per Terraform repository.
4. Each PR is titled
   `chore(metadata): remove inactive module owners [AVM owner audit]`. It
   gets the `Type: AVM` and `Needs: Core Team` labels where those exist, and
   requests review from `@Azure/azure-verified-modules-module-owners` and
   `@Azure/azure-verified-modules-engineering-owners`. The body links the
   orphan issues and @mentions the removed owners, and each orphan issue gets
   a comment linking the PR.
5. A repository that already has an open `avm-owner-audit/*` PR is skipped.

These are metadata-only changes, so no module release is needed. The catalog
sync publishes the new ownership. Labels are never created, child metadata is
never edited, and the tool does not change repository permissions.
