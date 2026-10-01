# Centralize standard GitHub labels

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-avm-labels-ownership`

## Outcome

Keep the standard AVM GitHub labels in one JSON file in this repository. Terraform
repository sync reads the local JSON instead of downloading the documentation CSV.
Tools-owned automation reconciles the AVM and Bicep repositories and proposes a
generated CSV update for the public documentation site. The site retains its
existing CSV URL and rendered labels table.

## Checklist

- [x] Convert the existing 45 labels to validated JSON without losing published
      label names, colors, or documentation descriptions.
- [x] Read the local JSON from Terraform repository sync and test its default
      path and 45-label output with mocked Terraform providers.
- [x] Add tested, tools-owned label reconciliation for the AVM and Bicep repos.
- [x] Generate the public CSV from JSON and propose changes in the AVM repo.
- [x] Remove the old AVM and Bicep label-sync workflows and redundant AVM script
      on their own branches, preserving the Bicep pull-request label check.
- [x] Run the repository's pre-commit gate, commit, push, and link the resulting
      changes.

## Validation

- `./build.ps1 pre-commit`: final run passes layout, lint, 1,928 unit tests,
  and 911 component tests after the Terraform test and workflow-trigger updates.
- `./build.ps1 test-tenant-terraform`: Terraform `fmt`, `init`, `validate`,
  and all 11 mocked-provider repository-sync tests pass with the local JSON
  default; the four BAMI identity tests also pass.
- A read-only publication check confirms the JSON generates the same 45 label
  rows as the existing public AVM CSV.
- The new workflow YAML parses, and `git diff --check` reports no errors.
- No production label sync or documentation publication was run.

## Dependencies

The AVM repository must retain
`docs/static/governance/avm-standard-github-labels.csv` because its Hugo
shortcode reads the file during site builds. Land the tools-owned sync before
removing the old AVM and Bicep label-sync workflows.

The independently reviewed removals are
[Azure/Azure-Verified-Modules#3018](https://github.com/Azure/Azure-Verified-Modules/pull/3018)
and
[Azure/bicep-registry-modules#7428](https://github.com/Azure/bicep-registry-modules/pull/7428).
The AVM change preserves the public CSV/table and removes its obsolete label
script; the Bicep change preserves its pull-request label check.
