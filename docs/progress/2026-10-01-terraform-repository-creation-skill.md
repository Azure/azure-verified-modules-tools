# Agent skill: create a Terraform module repository

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-repo-creation-push-failure`

## Outcome

Adds the `avm-tf-module-repository-creation` agent skill in
`.github/skills/`. It guides an agent through creating an AVM Terraform module
repository with `avm init -Ecosystem terraform`, based on the live setup of
`Azure/terraform-azure-avm-res-signalrservice-webpubsub`:

1. Check the prerequisites, including the `gh` scopes and clearing a
   `GH_TOKEN` that lacks them.
1. Collect approved values from the module proposal, asking the user one
   question at a time for the repository name, display name, description,
   canonical type, and owners.
1. Preview with `-WhatIf` and get approval before any production change.
1. Pass every value with `-InputObject`, because agent shells cannot answer
   prompts. Relay the Open Source Portal and elevation steps, then rerun.
1. Tie the repository to the shared JIT rule, or email avm@microsoft.com
   without permission.
1. Verify the result and recover from each error `avm init` reports.
1. As the last step, once everything else is done, make `jaredholgate` and
   `jatracey` the only individual Direct Owners, with the portal details the
   live setup showed: elevate first, use **Change owners** on the overview,
   and fill the two required owner slots before saving.

The skill ships with the `avm init` repository setup in the same pull request.

## Checklist

- [x] Write the skill with the documented `name` and `description`
  frontmatter and no pre-approved tools, because it changes production systems.
- [x] Check that every error message the recovery table quotes exists in the
  `Avm.Authoring` source.
- [x] Link the skill from the repository management README and the CHANGELOG.

## Validation

- Every quoted `avm init` error message was found in `src/Avm.Authoring`.
- `./build.ps1 pre-commit` passed with the change.

## Blockers or dependencies

The skill needs the `Avm.Authoring` release that includes Terraform
repository setup in `avm init`.
