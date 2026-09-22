# Metadata-driven issue owner routing (Bicep)

Status: complete
Branch: jaredfholgate-avm-reviewer-issue-routing

## Outcome

Second slice of the metadata-driven AVM reviewer/issue routing effort. Ports
`Set-AvmGitHubIssueOwnerConfig`/`Set-AvmGitHubIssueOwnerConfigForIssue` from
the retired `bicep-registry-modules` platform tooling (git history commit
`2eb210dbb`, removed in `Azure/bicep-registry-modules#7378`) into this
repository, reusing slice 1's owner-resolution library
(`ModuleOwners.ps1`) and its index-first/`metadata.json`-fallback design.

## Scope changes from the original

- **GitHub Project assignment is not re-ported.** This repository already has
  a generic, tested GitHub Projects (v2) sync script,
  `repository-management/repository-sync/scripts/Add-RepositoryItemsToProject.ps1`,
  currently used for the Terraform module repositories'
  `repository-management-sync.yml`. Rather than re-port
  `Add-GitHubIssueToProject.ps1`/`Get-GitHubIssueProjectAssignment.ps1`, the
  plan is to point that existing script at `bicep-registry-modules` /
  project 566 ("AVM - Module Issues") as its own workflow step. **Not wired
  into this slice's workflow yet** -- it needs its own permission check (see
  open items) and is independent of owner routing, so it is left as a
  follow-up rather than blocking this slice.
- **The original's console-only assignee/module distribution statistics
  reporting is dropped.** It was informational only, not routing behaviour.
- **The `issues: [opened]` trigger is dropped**, per the standing design
  decision to never run cross-repo, privileged automation off of untrusted,
  externally-triggerable events. This run is `workflow_dispatch` only until
  live validation is complete. Immediacy on new issues is lost; see open
  items.

## Checklist

- [x] `repository-management/reviewer-routing/scripts/lib/ModuleOwners.ps1`
      -- added `Test-AvmBicepModuleExists` (catalog-index membership or
      `metadata.json` presence at a ref), used to distinguish "module does
      not exist yet" from "module exists but has no declared owners
      (orphaned)".
- [x] `repository-management/reviewer-routing/scripts/lib/IssueOwnerRouting.ps1`
      -- `Get-AvmIssueOwnerRoutingCandidates` (single-issue or
      `updatedAt`-windowed sweep, filtered to `[AVM Module Issue]`-titled
      issues), `Get-AvmIssueOwnerRoutingTimeline` (paginated
      `.../issues/{n}/timeline`, used to distinguish a human's manual
      assign/unassign decision from a prior automated routing write),
      `Get-AvmIssueOwnerRoutingModuleReference` (extracts the module
      path/type the issue template's module dropdown wrote into the body),
      `Resolve-AvmIssueOwnerRouting` (side-effect-free routing decision:
      three distinct reply states -- module doesn't exist, module exists but
      orphaned, module exists and owned -- label, comment idempotency by
      age/orphan status, and assignee add/remove computed from the
      timeline), `Set-AvmIssueOwnerRoutingForIssue` (conditional
      application -- a no-op write is skipped so a reprocessed issue does
      not keep re-entering the scheduled lookback window), and
      `Invoke-AvmIssueOwnerRouting` (sweep; one failing issue does not abort
      the run).
- [x] `repository-management/reviewer-routing/scripts/Invoke-AvmIssueOwnerRouting.ps1`
      entry point, mirroring slice 1's dot-sourcing/strict-mode pattern.
- [x] `.github/workflows/repository-management-issue-owner-routing.yml` --
      `workflow_dispatch` only while live validation is pending, cross-repo
      `create-github-app-token` scoped to
      `bicep-registry-modules` (`issues: write`), `environment: avm` gate.
      The disabled schedules (`9,24,39,54 * * * *` and `17 3 * * *`) are
      preserved in comments.
- [x] `tests/Pester/Unit/RepositoryManagement/IssueOwnerRouting.Tests.ps1`
      (22 tests): module-reference extraction, candidate filtering
      (title-prefix and lookback window), all three reply/label states,
      comment age/orphan idempotency, assignee add/remove with
      timeline-based manual-action guards (a manually unassigned owner is
      not re-added; a manually assigned non-owner is not removed; a
      bot-assigned non-owner is removed), conditional-write no-op, and an
      `'Issue owner routing workflow safety'` guard context mirroring
      slice 1's (`workflow_dispatch`-only, never `schedule`, `issues:`,
      `pull_request`, or `pull_request_target`, disabled cron preservation,
      direct dispatch input mapping, and no `${{ }}` interpolation into a
      `run:` body).
- [x] Applied the same design-invariant lesson learned while fixing slice 1
      (team-vs-user must be decided by an owner's `Type`, never by inferring
      from a `/` in the handle): `Resolve-AvmIssueOwnerRouting` filters
      `$_.Type -ceq 'user'` for assignable owners and mentions every owner
      (`$_.Handle`) regardless of type in the reply comment, since teams can
      be `@`-mentioned in text but not assigned to an issue.
- [x] Ran the new test file in isolation (22/22 passing), then the full
      `./build.ps1 pre-commit` gate.

## Follow-ups / open items still to confirm with Jared

- Whether to wire `Add-RepositoryItemsToProject.ps1` into this workflow for
  `bicep-registry-modules` / project 566, and if so, whether the AVM App's
  token needs an additional org-level Projects v2 permission (exact
  `create-github-app-token` input name for that permission is not yet
  confirmed against a working example in this repository).
- Whether the AVM GitHub App has `Issues: write` on `bicep-registry-modules`
  -- not verified from this session; flagged rather than worked around.
- Losing the `issues: [opened]` immediacy: if fast issue triage matters,
  consider a `repository_dispatch` sent from `bicep-registry-modules` on
  issue open, processed by this same workflow's `workflow_dispatch` path
  (out of scope for this slice).
- This is slice 2 of 4. Workflow-failure issue management and module
  dropdown auto-sync are separate, not-yet-started slices tracked under the
  same branch.
