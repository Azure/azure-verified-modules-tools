# Local Bicep module scaffolding

**Status**: complete
**Started**: 2026-09-26
**Updated**: 2026-09-26
**Branch**: `jaredfholgate-interactive-metadata-initialization`

## Outcome

Make non-proposed `avm init` create the one-time local Bicep module scaffold:
validated metadata and main.bicep for root or child modules, plus root-only
version.json, CHANGELOG.md, and defaults/WAF-aligned e2e test sources.
Deep child initialization creates missing ancestors in one transaction, with
explicit path-keyed inputs for scripted callers.
Keep `-Proposed` metadata-only, preserve existing authored files and telemetry
prefixes, and leave main.json/README generation, remote operations, and
deployment to separate workflows.

## Checklist

- [x] Confirm the child-path input contract and port the upstream templates
      into the packaged module.
- [x] Plan and validate all new files before writing; preserve existing files,
      support WhatIf, and clean up on partial failure.
- [x] Cover proposed-to-full transition, root/child paths, invalid input,
      existing authored files, WhatIf, and rollback in focused tests.
- [x] Update the directly related CLI/spec/plan documentation.
- [x] Pass `./build.ps1 pre-commit`, commit, and push this slice.

## Validation

Targeted Component suites: 30 full-scaffold cases and 20 existing metadata-only
cases pass. `./build.ps1 pre-commit`: layout and lint passed, 1,840 unit tests
passed (9 skipped), and 875 component tests passed. Generated root, child,
utility, and root e2e Bicep sources compiled locally with the pinned CLI.

## Blockers and dependencies

The recursive child contract is confirmed: `-InputObject` describes the target
and `-AncestorInputObject` maps missing parents by root-relative path.
Full README generation and static checks are separate follow-on slices.
