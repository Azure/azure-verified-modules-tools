# TFLint module-class candidate previews

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Confirm the released TFLint module-class integration through targeted,
plan-only repository-sync candidates, with publication and project
synchronization disabled.

## Checklist

- [x] Wait for the existing scheduled sync without displacing it.
- [x] Preview the regions utility against pushed source `691b187`.
- [x] Preview a pattern after the standard telemetry unit-mock migration is safe.
- [x] Record exact validation outcomes and confirm publication was skipped.
- [x] Record the final automatic CI outcome.

## Validation

The existing scheduled sync
[36985954749](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36985954749)
completed successfully.

The [regions preview](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36995072581)
used Tools `691b187` and module main
`abcc7c4138028371e88aa8d0be60a6537b08c40e`. Prepare reported
`hasChanges: false`, Validate reported `NoChange`, and Publish was skipped.
The utility's 12 existing unit-test files were not executed. This confirms
no candidate changes, not successful module-class lint or unit validation.

Virtual WAN and hubnetworking are archived. Repository discovery already
excludes archived repositories; the requester confirmed they must be ignored.
No archive-specific repair or preview is planned. Select only active,
published patterns with genuine existing unit suites. ALZ management main
still lacks a unit suite; do not fabricate tests or skip that gate.

Selected active pattern:
`Azure/terraform-azurerm-avm-ptn-azuremonitorwindowsagent`, published as
v3.0.0, with main at `f81345c6b353b4646f9ddf5154c3f296fb18ed58`.
Its two existing provider-mocked plan tests check existing-rule reuse and
regional placement of newly created monitoring resources. Both explicitly
disable telemetry; preserve that authored choice. The separate real-tool
regression exercises enabled telemetry under mocks. No open module review
was found at selection time.

The [active-pattern preview](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36998167145)
passed against Tools `f989980b52a65894dd16c47bf55baf51c3474669`,
which includes the fully gated unit-mock migration. Inputs keep
`plan_only=true`, workflow authoring source enabled, forced file updates
disabled, and both project-sync options disabled. Running, queued, waiting,
requested and pending sync counts were all zero immediately before dispatch.
Prepare and Validate passed; Publish was skipped. The receipt matches
base `f81345c6b353b4646f9ddf5154c3f296fb18ed58` and candidate tree
`a5da9ceb70d9ef969b81d0b18bab207334f6ef05`.
Actual Terraform output confirms both existing unit runs passed:
`uses_external_rule_without_creating_data_collection_resources` and
`uses_location_for_new_data_collection_resources`. The candidate changes
only README, telemetry source, provider requirements and standard mocks;
the original assertions and telemetry opt-outs remain unchanged.

Lint passed while reporting notice-level provider/interface findings.
Those notices were not suppressed or promoted to failures for this preview.
The unchanged module already declares the product's AzAPI monitor-agent
resource. Policy checking reported skipped, not a policy-plan pass.

[Automatic CI for the same source](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36998037102)
also passed: all platform test and integration jobs completed successfully.
Neither job was approved, cancelled or rerun.

Preflight of the active ALZ hub-and-spoke pattern found tests that explicitly
run a local child module. The current conservative mock migrator rejects
that shape; handle it in the
[unit-test-scope slice](2026-10-02-telemetry-unit-test-scope.md), not through
module-specific repairs or a knowingly failing remote dispatch.

## Blockers or dependencies

The pattern and current-source CI are qualified at the exact revisions above.
The utility remains a no-change result, not a unit-test qualification.
The separate unit-test-scope slice owns the discovered networking case.
No module publication, deployment, or protected-job approval was performed.
