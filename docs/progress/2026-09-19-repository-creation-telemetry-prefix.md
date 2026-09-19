# Generate telemetry identifiers during repository creation

- **Status**: complete
- **Started**: 2026-09-19
- **Branch**: `jaredfholgate-repo-creation-check`

## Outcome

`New-Repository.ps1` mints a unique `telemetryIdPrefix` when the operator does not
supply one, so creating a Terraform module repository no longer depends on
someone hand-picking an identifier.

## Background

The `Module Metadata Catalog Sync` run
[35404840363](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35404840363)
held back `TerraformPatternModules.csv` and `TerraformResourceModules.csv`
because 17 proposed modules name a repository that does not exist. Creating
those repositories requires a telemetry identifier, but creation only passed
`-telemetryIdPrefix` straight through to metadata and never generated one.

Observed convention across the fleet: `46d3xtrf.<res|ptn|utl>.<7 lowercase hex>`.
All 388 Terraform prefixes in the catalog are distinct and exactly 7 characters,
and the value is not derived from the module name.

## Checklist

- [x] Collect known prefixes from the published catalog
- [x] Generate a random, unique prefix when one is not supplied
- [x] Warn rather than fail when the catalog cannot be resolved
- [x] Leave telemetry-free `avm-utl-` roots without a generated identifier
- [x] Unit and component coverage
- [x] `./build.ps1 pre-commit`

## Validation

`./build.ps1 pre-commit` green: 1659 unit tests passed (0 failed, 8 skipped) and
826 component tests passed (0 failed, 1 skipped).

Generation was also exercised against the real fleet: 17 prefixes generated
against the 993 known catalog prefixes produced no collisions, all matching
`^46d3xtrf\.(res|ptn)\.[0-9a-f]{7}$`.

## Notes

Generation deliberately skips `avm-utl-` roots. Utilities may be telemetry-free,
and the component suite asserts that an omitted identifier stays omitted for
them; only resource and pattern roots require one.
