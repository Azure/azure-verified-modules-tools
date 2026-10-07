# Bicep native validation completion

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-06
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
- [x] Compare pinned registry assertions with packaged native requirements.
- [x] Replace convention family wrappers with independent native assertions.
- [x] Move explicit shared JSON and Bicep source-literal checks into native Pester.
- [x] Migrate compiled telemetry/metadata agreement with the convention assertions.
- [x] Package common PSRule defaults and remove policy's required registry utility reads.
- [x] Wire metadata, convention, unit compliance, and composition entry points.
- [x] Add reusable Bicep whole-module fixtures and independent-package acceptance.
- [x] Record positive and negative evidence for every migrated requirement.
- [x] Run the ordinary local gate and commit qualified correctness slices.
- [ ] Publish the held commits and obtain current-head hosted evidence.
- [x] Measure and improve CI only after correctness and fixture qualification.

## Requirement map

Registry reference:
`Azure/bicep-registry-modules@ca00e89a931f637f628503a3a625e7d487157496`.
Map and evidence are populated as each requirement is migrated, not inferred
from family names or an aggregate passing command.

| Existing requirement source | Packaged destination | Evidence |
| --- | --- | --- |
| `compliance/module.tests.ps1` compiled template, parameters/UDTs, telemetry and outputs | `Resources/bicep/conventions/Compiled.Tests.ps1` | [Compiled map](2026-10-05-native-compiled-conventions.md): positive root/child and native compiler controls; individual naming, schema, typing, forwarding and output negatives |
| Shared metadata schema and source-literal validation | `Resources/metadata/Metadata.Tests.ps1`, shared across Bicep and Terraform | Paired native/internal constraints, file/InputObject routing, batched composition, five copied-package acceptance cases |
| `compliance/metadata.tests.ps1` compiled telemetry-prefix agreement | `Resources/bicep/conventions/Compiled.Tests.ps1` | Direct/one-alias agreement, source readers, versioned children, drift failures and five real compiler/scaffold cases |
| `psrule/ps-rule.yaml` and eight `.ps-rule/*.Rule.yaml` assets | `Resources/bicep/psrule/` | Real built-package baseline execution and insecure-transport rejection; 17 unit and 21 component controls |
| Layout, required tests, casing and exclusions (73-375) | `Layout.Tests.ps1` | [Final-family map](2026-10-05-final-native-convention-families.md): 22 native positives and missing/casing/link/UTF-8/exclusion negatives |
| Workflow paths, inputs, defaults, trigger and initializer (380-611) | `Workflow.Tests.ps1` | [Workflow map](2026-10-05-native-workflow-ownership.md): 20 native positives and malformed/missing/overbroad workflow negatives |
| CODEOWNERS defaults and override order (2056-2084) | `Ownership.Tests.ps1` | Same map: 17 native positives and owner, duplicate, broad-pattern and ordering negatives |
| Child publication permission | `ChildPublish.Tests.ps1` | [Child map](2026-10-05-native-child-publishing.md): portable `.avm` allowlist, missing/malformed/duplicate/unapproved child negatives |
| Versions and changelog structure | `Version.Tests.ps1` | [Version map](2026-10-05-native-version-conventions.md): 14 native positives and 13 located format/exemption negatives |
| Published history and ancestor updates (1666-2055) | `Publication.Tests.ps1` | Final-family map: four native positives plus unknown release, absent target, unreadable changelog and ancestor negatives |
| Test-source naming, descriptions and compiled `testDeployment` (2127-2295) | `TestSource.Tests.ps1` | [Test-source map](2026-10-05-native-test-source-conventions.md): 27 native positives and source/compiled violations |
| Resource API catalog and recency (2296-2475) | `ApiVersion.Tests.ps1` | [API map](2026-10-05-native-api-conventions.md): six migrated cases plus eleven catalog/diagnostic controls |
| Generated README presence, drift and grouping comments | `Readme.Tests.ps1` | [README map](2026-10-05-native-readme-compliance.md): real rendering, absent/empty/stale README and advisory controls |
| Module-authored unit/e2e tests and module configuration | Remain consumer-owned | Default compliance aggregates a real isolated authored unit test; e2e runner retains module-owned assertions and package-owned orchestration |

## Final ownership and entry-point audit

`Test-AvmModuleMetadata` uses `Invoke-AvmMetadataSuite` for both ecosystems.
`Test-AvmMetadataModules` batches the same native metadata requirements in
pre-commit and pr-check. Internal construction/parsing guards share the schema
without starting a test framework, as approved by the user.
`Invoke-AvmCheckConvention` uses the native convention suite; `Invoke-AvmDocs
-CheckDrift` uses native README assertions. Pr-check composes these native
entry points and genuine packaged PSRule evaluation. Pre-commit retains its
format/compiler/transform/document-generation semantics, with native metadata.
Default `Invoke-AvmTestUnit -Recurse -IncludeCompliance` prepares inputs once and
combines the native suites in one run; explicit authored overrides remain
explicit. Native execution counters, skipped/failed containers and missing
diagnostics cannot silently pass.

Source reads/calls and packaged configuration were inspected beyond Test-*
names, including README rendering, compiled JSON, scopes, policy configuration,
unit/e2e assertions and publication history. No mandatory utility path remains.
Registry names retained in workflow/changelog expectations are module conventions,
not runtime script loads. Publication history reads only module main/version data
and release tags; the independent path requires no registry checkout. Compiler,
JSON/YAML parsing, deployment ownership/run-ID predicates and test orchestration
remain implementation code, not competing shared assertion engines.

`bicep-storage`, `bicep-docs` and `bicep-existing-references` are authoritative
whole-module fixtures alongside Terraform. Their command/framework coverage
includes metadata/telemetry, UDT/parameters/outputs/docs, local children/helpers,
scopes, Graph/Key Vault existing references, authored tests and policy.
Focused malformed snapshots remain separate. The final copied-package route
passes exactly 187 native/authored cases and four diagnostic mutations;
real PSRule runs eight baselines across two examples and rejects insecure storage.
Publication/API/MCR data is simulated explicitly, never represented as live
upstream verification.

Companion registry cleanup remains a separately approved cutover: keep existing
compliance module/metadata entry points and PSRule files until a compatible
release advertises `BicepPackagedCompliance = 1`; then replace shared-validation
calls with package commands, retaining module source/assertions/configuration
and moving child-publication configuration to `.avm`. No registry files were
deleted, no release published and no workflow cutover performed.

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

The [native child publishing slice](2026-10-05-native-child-publishing.md) replaces
the child wrapper with independent native file, configuration and membership
requirements. The authoritative consumer configuration is now
`.avm/child-module-publish-allowed-list.json`; no legacy utility fallback remains.
Five families remain: layout, versions, API versions, test files and publication.
Its Pester 5/6 focused runs and full Pester 6 gate are green.

The [native version slice](2026-10-05-native-version-conventions.md) removes the
version family wrapper and checker. Fourteen native requirements cover the
valid fixture, with explicit exemption and thirteen diagnostic/line negatives.
Four families remain: layout, API versions, test files and publication.

The [native API slice](2026-10-05-native-api-conventions.md) removes the API
checker and family wrapper. Its six former unit cases now execute native
Pester, with eleven additional catalog/diagnostic controls. Three families
remain: layout, test files and publication.

The [native test-source slice](2026-10-05-native-test-source-conventions.md)
replaces the test-file checker and reuses the compiler's collected source
inventory. Its native-only control runs 27 requirements; Pester 5/6 and the
full gate are green. Layout and publication are the remaining family wrappers.

The [final convention-family slice](2026-10-05-final-native-convention-families.md)
removes the layout/publication checkers, generic family wrapper and test-only
importer. All twelve former families now use native Pester requirements.
The Pester 6 full gate and Pester 5 focused run pass; native-only controls
execute 22 layout and four publication cases. Default unit compliance,
native README comparison, complete package acceptance and CI review remain.

The [native README slice](2026-10-05-native-readme-compliance.md) moves
existence, byte comparison and grouping-comment advisories into packaged Pester.
The full Pester 6 gate, focused Pester 5 checks and five real compiler-only docs
integration cases pass. The default unit compliance route is the next change.

## Blockers or dependencies

All authorized local implementation is qualified. Final defaults and stale-ref
corrections are in `de61ab7`; independent acceptance no longer writes a caller
Scriban template or documentation override. The
[CI runtime review](2026-10-06-ci-integration-deduplication.md) preserves all
OS/coverage/fixture cases and removes only duplicate Bicep executions.
Its measured aggregate Windows Bicep time is 575.10 -> 300.14 seconds for the
same 18 distinct cases; no whole-workflow speedup is claimed.
Final serial/sharded unit cases reconcile (3,028 pass, nine skip), the full
local gate is green, and Windows local coverage is 73.8% against the 70% floor.
No job remains running. Publishing and current-head hosted qualification are
the only remaining delivery blockers; release/registry cutover is not authorized.

Publishing `d3fac2a` and later qualified commits is blocked by the OAuth App's
missing workflow scope. The coordinator confirmed that no authentication
change or alternate route is authorized. Preserve qualified commits locally and
continue source-only migration, tests and documentation.

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
