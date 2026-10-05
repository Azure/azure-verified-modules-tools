# Bicep native validation completion

**Status**: in-progress
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Complete shared validation ownership in Avm.Authoring: native packaged Pester
assertions, packaged PSRule configuration, independent consuming-module
fixtures, and then an equivalent-work CI performance review. Historical
passing gates do not establish that this migration is complete.

Adopted the released existing branch in an isolated worktree and fast-forwarded
to `5a6e46ede16224c281fa4146023d5eae3adf6ea5`, matching the live head of
[#221](https://github.com/Azure/azure-verified-modules-tools/pull/221).
The checkout was clean. No replacement branch or review was created.

## Checklist

- [x] Verify same-branch ownership and preserve the newer remote commits.
- [x] Read progress protocol, active records, agent contract, and relevant standards.
- [ ] Compare pinned registry assertions with packaged native requirements.
- [ ] Replace convention family wrappers with independent native assertions.
- [x] Move explicit shared JSON and Bicep source-literal checks into native Pester.
- [x] Migrate compiled telemetry/metadata agreement with the convention assertions.
- [x] Package common PSRule defaults and remove policy's required registry utility reads.
- [ ] Wire metadata, convention, unit compliance, and composition entry points.
- [ ] Add reusable Bicep whole-module fixtures and independent-package acceptance.
- [ ] Record positive and negative evidence for every migrated requirement.
- [ ] Run the ordinary local gate, commit, and push the correctness slice.
- [ ] Measure and improve CI only after correctness and fixture qualification.

## Requirement map

Registry reference:
`Azure/bicep-registry-modules@ca00e89a931f637f628503a3a625e7d487157496`.
Map and evidence are populated as each requirement is migrated, not inferred
from family names or an aggregate passing command.

| Existing requirement source | Packaged destination | Evidence |
| --- | --- | --- |
| `compliance/module.tests.ps1` compiled template, parameters/UDTs, telemetry and outputs | `Resources/bicep/conventions/Compiled.Tests.ps1` | Native requirement map and positive/negative controls in the compiled slice; eight other families remain |
| Shared metadata schema and source-literal validation | `Resources/metadata/Metadata.Tests.ps1`, shared across Bicep and Terraform | Paired native/internal constraints, file/InputObject routing, batched composition, five copied-package acceptance cases |
| `compliance/metadata.tests.ps1` compiled telemetry-prefix agreement | `Resources/bicep/conventions/Compiled.Tests.ps1` | Direct/one-alias agreement, source readers, versioned children, drift failures and five real compiler/scaffold cases |
| `psrule/ps-rule.yaml` and eight `.ps-rule/*.Rule.yaml` assets | `Resources/bicep/psrule/` | Real built-package baseline execution and insecure-transport rejection; 17 unit and 21 component controls |
| Module-authored unit/e2e tests and module configuration | Remain consumer-owned | Pending entry-point audit |

## Validation

Policy-specific validation:

- `.\build.ps1 test,component -TestName 'Bicep PSRule*'`: 17 unit and 21
  component tests passed. Component consumers remove their registry PSRule
  directory. Negative tests reject missing package assets and executable rules.
- `.\build.ps1 build,integration -TestName 'Integration: packaged Bicep policy*'`
  built and imported a copied distribution, rather than the source module.
  Initial failures exposed a nullable-parameter fixture error and missing blob
  retention. After correcting the fixture,
  `.\build.ps1 integration -TestName 'Integration: packaged Bicep policy*'`
  passed both controls: all four baselines processed rules; insecure transport
  failed `Azure.Storage.SecureTransfer` in `CB.AVM.WAF.Security`.
- Common policy data preserves the pinned registry's options, exclusions, and
  all eight YAML definitions; only explanatory comments were omitted.

The full gate passed: 3,010 unit tests (nine skipped) and 1,458 component
tests (one skipped), zero failures; layout and lint passed. Total 6m39.7s is
an observation, not a comparable performance improvement.
The remaining native assertion migration is not yet qualified.
No cloud execution, host-security change, release,
workflow dispatch, merge, or registry cutover is authorized or performed.
Build and test commands use `.\build.ps1`; broad integration setup is excluded.

The [shared native metadata slice](2026-10-05-shared-native-metadata.md) now
passes the full gate: 3,010 unit tests (nine skipped) and 1,478 component tests
(one skipped), plus five copied-package acceptance cases. Explicit metadata
validation uses the same six native JSON requirements for both ecosystems;
Bicep source checks add four cases. Internal guards evaluate the exact same
schemas without starting Pester. Composition batches all scopes.

The [native compiled slice](2026-10-05-native-compiled-conventions.md) now removes
four ordinary checker implementations and their family wrapper. Full Pester 6.2.0
gate: 3,001 unit passed / nine skipped and 1,497 component passed / one skipped.
Pester 5.7.1 focused compatibility: 153 passed / one skipped. The
[hosted fixes](2026-10-05-native-validation-hosted-fixes.md) remove dependency
warning leakage, build package acceptance inputs and preserve failed-setup
diagnostics. Eight other convention families, default unit compliance,
child-publish configuration portability and final acceptance remain outstanding.

The [workflow/ownership slice](2026-10-05-native-workflow-ownership.md) removes
two more checker families. Its native-only positive control runs 37 independent
requirements; full gate is green with Pester 6 and focused compatibility with
Pester 5. Six families remain: layout, versions, API versions, test files,
publication history and child publishing.

## Blockers or dependencies

The user approved shared ordinary schema/parsing/value primitives for internal
construction, prompts, initialization, and discovery. Explicit metadata
validation, including InputObject, must share one packaged native Pester
assertion set across Bicep and Terraform. Bicep source-wiring tests are separate.
No duplicated ecosystem-specific metadata implementation is permitted.

The [fixture curation slice](2026-10-05-bicep-module-fixtures.md) moved the
documentation module tree and extracted the existing-reference compiler
fixture. Native compliance package acceptance remains outstanding.

The [package-owned PSRule slice](2026-10-05-bicep-packaged-psrule.md) is qualified.
Existing registry entry points remain untouched until
a separately approved compatible release and cutover. A concise companion
technical-doc update should describe the package-owned validation boundary
in Azure-Verified-Modules-Docs after implementation is qualified.

The separate workflow migration owners agreed on the future manifest marker
`PrivateData.AvmCapabilities.BicepPackagedCompliance = 1`. Do not advertise it
until the default `Invoke-AvmTestUnit -Recurse -IncludeCompliance` route and
acceptance prove native conventions, compiled checks, README drift,
metadata/source validation and module-authored unit tests. It excludes PSRule and
e2e. Intermediate packages must continue failing the migration's capability gate.
