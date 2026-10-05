# Help and comment review

- Status: complete
- Started: 2026-10-05
- Branch: jaredfholgate-avm-authoring-refactor
- Parent record: [Avm.Authoring refactor](2026-10-03-avm-authoring-refactor.md)

## Outcome

Public help and shipped comments now describe current behaviour without
pointing readers at design-spec sections, phase numbers or progress IDs.

## Checklist

- [x] Remove spec-section, phase and `F###` references from shipped code
      comments, help, the `AvmAvoidStringThrow` rule message and the
      PSScriptAnalyzer settings comment.
- [x] Replace the stale "fails closed until registry parity" convention help.
- [x] Rewrite the Terraform engine README, which still described an empty
      Phase 0 folder, and the "bicep walker pending" README note.
- [x] Document `-SkipModuleVersionCheck` on the 21 public commands that
      lacked it. Every public parameter now has help text.
- [x] Leave test names and test-only comments alone; they are not shipped.

## Validation

- Every exported command's non-common parameters have help descriptions
  (checked with `Get-Help` after importing the source module).
- PSScriptAnalyzer clean on changed source files.
- `./build.ps1 pre-commit` passed in 13m35s: 2,977 unit tests; 1,280 component
  tests passed and 1 skipped across six shards.
