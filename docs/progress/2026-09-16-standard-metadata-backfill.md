# Standard repository-sync metadata backfill

**Status**: complete
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-standard-metadata-backfill`

## Outcome

Make the manual, default-off metadata backfill a preparation hook in full
normal Terraform repository sync. On 2026-09-16 the user explicitly selected
full sync, including managed files, authoring, CODEOWNERS, repository/Azure
management and standard publication/merge, instead of metadata-only review.
The user also removed Terraform source-reader generation; later MaPoTF
telemetry work is out of scope. Existing metadata and authored source files
remain protected. Bicep's optional source wiring remains supported.

The temporary hook loads checkout metadata commands in a short-lived PowerShell
process through the existing transport; ordinary authoring keeps using the
installed release. A runspace was rejected after real import tests exposed its
process-wide module-discovery changes. No caller-wide state restoration is used.
Shared publication, merge, authentication, plan-only and tenant gates are not
replaced or relaxed.

## Checklist

- [x] Read contracts and verify the clean main-based branch at `dae8119`.
- [x] Replace the metadata-only workflow and driver paths with normal sync.
- [x] Isolate temporary metadata preparation before normal pre-commit.
- [x] Remove Terraform reader generation and reject unsupported requests.
- [x] Cover real imports/preparation, normal controls, failures and no-overwrite.
- [x] Update current help, specification, migration and rollout documentation.
- [x] Pass the local gate and independent review.

## Validation

`.\build.ps1 pre-commit` passed: layout, lint, 1,515 unit tests (8 existing
skips), and 526 component tests. The first full run exposed three workflow
extraction tests tied to an old step display name; their selector now includes
the required `[AVM]` prefix and all three pass without changing backend behavior.
Both tests selected by
`.\build.ps1 integration -TestName 'Integration: module metadata native readers*'`
passed, including Bicep compilation and provider-free Terraform plans.

Real process/import tests
prove checkout-only metadata preparation, unchanged caller commands and
`PSModulePath` with an installed module lacking metadata APIs, error/warning
propagation, request cleanup, and normal publication/merge with external writes
stubbed. JSON request parsing also preserves ISO-looking strings.
Independent Opus 5 review reported no findings and confirmed that the shared
publisher and process transport are unchanged. Verify hosted checks against the
new review's exact head before merging; local evidence is not a hosted-check
substitute.

## Blockers and boundaries

None. Implementation approval is not approval for production execution.
Do not dispatch workflows, change settings/access, apply infrastructure, or
merge the tools change. Leave
[Azure/terraform-azurerm-avm-ptn-example-repo#298](https://github.com/Azure/terraform-azurerm-avm-ptn-example-repo/pull/298)
and its branch untouched. The parent session coordinates team documentation.
