# Workflow naming consistency

Status: complete
Started: 2026-09-23
Updated: 2026-09-23
Branch: jaredfholgate-workflow-naming-consistency

## Outcome

The Actions sidebar mixed three naming styles and truncated most
repository-management workflows. Workflow display names now use a short
`<Group>: <Name>` form that groups related workflows and fits the sidebar.

| File | Old name | New name |
| --- | --- | --- |
| `ci.yml` | CI | Authoring: CI |
| `release.yml` | Publish signed release | Authoring: Release |
| `terraform-module.yml` | AVM Terraform Module | Reusable: Terraform Module |
| `module-metadata-sync.yml` | Module Metadata Catalog Sync | Repos: Catalog Sync |
| `repository-management-bicep-sync.yml` | Repository Management - Bicep Sync | Repos: Bicep Sync |
| `repository-management-config-test.yml` | Repository Management - Configuration Tests | Repos: Config Tests |
| `repository-management-issue-owner-routing.yml` | Repository Management - Issue Owner Routing | Repos: Issue Routing |
| `repository-management-module-list-sync.yml` | Repository Management - Module List Sync | Repos: Module List Sync |
| `repository-management-pr-reviewer-routing.yml` | Repository Management - PR Reviewer Routing | Repos: PR Routing |
| `repository-management-sync.yml` | Repository Management - Terraform Sync | Repos: Terraform Sync |
| `repository-management-workflow-failure-issues.yml` | Repository Management - Workflow Failure Issues | Repos: Workflow Failures |

Job and step names now use sentence case without the repeated
`Repository Management -` or `[AVM]` prefixes, matching the earlier decision in
[`2026-09-18-catalog-snapshot-concurrency.md`](2026-09-18-catalog-snapshot-concurrency.md).
Terraform Sync matrix jobs are named `Sync <repository name>` instead of the
module ID plus the full repository URL, and its step names (and those of the
`avm-repos` composite action) use sentence case, for example
`Report sync issues` instead of `Issue Error`. CI jobs are `Lint`,
`Test (<os>)`, `Workflow tests` and `Integration (<fixture> on <os>)`.

File names are unchanged: consumer repositories, OIDC `job_workflow_ref`
claims and operator documentation reference them. Job names in
`terraform-module.yml` are unchanged because they appear in every calling
repository's checks. The GitHub-managed CodeQL, Copilot, Dependabot and Code
Coverage Agent entries cannot be renamed from this repository.

## Checklist

- [x] Confirm no branch ruleset or classic protection requires the renamed check names.
- [x] Confirm OIDC subjects use repository, environment or `job_workflow_ref`, not workflow names.
- [x] Rename workflow, job and step display names.
- [x] Update the test that located the `Resolve state backend` step by name.
- [x] Update `CONTRIBUTING.md` and document the convention in `docs/quality-standards.md` §13.

## Validation

`./build.ps1 pre-commit` passes. No workflow file contains CRLF line endings or
an `[AVM]` display-name prefix.

## Follow-up

The team documentation in Azure-Verified-Modules-Docs lists the old names in
`docs/inventory/pipelines.md`, `docs/testing/bami-operations.md` and
`docs/how-to/avm/avm-repo-mgmt/deploy-canary-managed-file-update.md`. Update it
once this change merges.
