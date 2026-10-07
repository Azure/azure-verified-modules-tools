# Command documentation generation

**Status**: blocked
**Started**: 2026-10-07
**Updated**: 2026-10-07
**Branch**: jaredfholgate-copilot-docs

## Outcome

Consolidate the repo's authoring guidance into a single Copilot instruction file and a single quality-spec document, then make the generated public cmdlet reference a required part of the validation contract.

## Checklist
- [x] Review current instruction and quality-doc structure
- [x] Establish doc-generation contract for public cmdlet reference pages
- [x] Update repo guidance to require regenerated docs for PR checks
- [x] Validate with the smallest relevant build/test command

## Validation
- `./build.ps1 pre-commit` reached layout + lint + test, with layout and lint passing.
- The repo-wide gate still failed in the existing component-test phase: 2 component tests failed, which blocks a fully green validation on this branch and is outside the documentation-only changes made here.

## Blockers / dependencies
- Repo-wide component tests are currently failing before a green pre-commit pass can be recorded for this branch.
