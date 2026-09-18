# Catalog: allow metadata-only modules, and plain-English `plan_only`

Status: complete
Started: 2026-09-18
Completed: 2026-09-18
Branch: jaredfholgate-workflow-input-wording

## Outcome

Two changes to the module metadata catalog sync:

1. A module folder that has `metadata.json` but no source yet is adopted as a normal
   `Proposed` catalog entry instead of aborting the whole collection run. A module that
   the registry reports as published must still have its source.
2. The `plan_only` workflow input description is written in plain English.

## Why

`Azure/bicep-registry-modules#7366` scaffolded 49 AVM module folders that contain only
`metadata.json`. `Get-AvmCatalogSources` discovered those folders (it accepts either
`main.bicep` or `metadata.json`) and then immediately threw
`Bicep module has no main.bicep: avm/ptn/ai-ml/landing-zone`, so every catalog run failed
from the moment that PR merged. Terraform had the mirror-image rule
(`Metadata has no Terraform source`). Both rules assumed metadata never exists ahead of
source, which is no longer true.

## Checklist

- [x] `New-AvmCatalogIdentity` carries `SourcePending`.
- [x] Bicep discovery marks `SourcePending` instead of throwing; a wrong-cased
      `Main.bicep` is still a hard error.
- [x] Terraform discovery mirrors the same rule.
- [x] Metadata validation skips `-CheckSource` while source is pending, because
      `Test-AvmModuleMetadata` requires `main.bicep` for the literal comparison.
- [x] `New-AvmCatalogBundle` throws when a source-pending module is anything other than
      `not-published` in the registry.
- [x] Component tests: scaffolded Bicep and Terraform modules adopt as `Proposed`; a
      published module missing its source still throws; wrong-case `Main.bicep` still
      throws.
- [x] `plan_only` description rewritten.
- [x] `./build.ps1 pre-commit` green.

## Validation

`./build.ps1 pre-commit` — `Build succeeded with warnings. 5 tasks, 0 errors`.

## Notes

The Terraform relaxation means a metadata-only family root now sets `$hasRoot`, so its
children are no longer rejected as parentless. That is the intended behaviour for a
scaffolded family and is covered by the new test case.

The wrong-case `main.bicep` guard previously used `(Get-Item $path).Name`, which on
Windows echoes the requested path rather than the on-disk name, so the guard only ever
fired on case-sensitive filesystems. It now enumerates the directory and compares the
real filename, which works on both.
