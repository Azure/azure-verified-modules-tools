# Interactive local module initialization

**Status**: complete
**Started**: 2026-09-26
**Updated**: 2026-09-26
**Branch**: `jaredfholgate-interactive-metadata-initialization`

## Outcome

Provide a one-time `avm init` command for local Bicep proposals and Terraform
metadata, including a `-Proposed` Bicep mode that creates only metadata.json
before main.bicep exists. Keep `avm metadata initialize` and the Terraform
repository-creation workflow compatible, without creating remote repositories
from the local command. Full Bicep source scaffolding is a follow-on slice.

## Checklist

- [x] Prompt for missing required metadata only in interactive terminals;
      validate supplied values, preserve existing files, and support WhatIf.
- [x] Automatically populate the packaged schema URI and missing Bicep
      telemetry prefix using published and local current/historical IDs.
- [x] Implement the `avm init` dispatcher for metadata-only proposed Bicep
      modules and local Terraform metadata without remote repository creation.
- [x] Update directly related command documentation and focused tests.
- [x] Pass `./build.ps1 pre-commit`, commit, push the feature branch, and
      open the requested pull request.

## Validation

Focused `./build.ps1 test` and `./build.ps1 component` selections passed for
the dispatcher, Bicep proposals, Terraform metadata, catalog availability,
missing/invalid prompts, nested directories, existing files, and remote
Terraform repository-creation callers. A live read of the public catalog
returned 1,612 current and historical identifiers. The first full
`./build.ps1 pre-commit` passed layout, lint, all 1,837 runnable unit tests
(9 skipped), and all 844 component tests. The first full gate exposed four
outdated Bicep assertions for missing telemetry; the `-UpdateSource` cases
now preserve an unambiguous prefix already authored in main.bicep and reject
explicit mismatches or identifiers claimed by other modules. Metadata-only
Bicep still generates a new prefix. Direct validation remains strict.

## Blockers and dependencies

Full Bicep scaffolding remains explicitly unsupported without `-Proposed`
until the upstream one-time template inventory is agreed. Do not migrate
repeatable Set-AVMModule work into `avm pre-commit` or `avm pr-check` until
its responsibilities are confirmed.
