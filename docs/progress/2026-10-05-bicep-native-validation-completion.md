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
- [ ] Move shared Bicep metadata assertions into a packaged native suite.
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
| `compliance/module.tests.ps1` and twelve convention checker families | Pending native assertion migration | Pending |
| `compliance/metadata.tests.ps1`, metadata schema and source validation | Pending packaged metadata suite | Pending |
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

## Blockers or dependencies

The metadata boundary decision is with the user through the coordinator:
internal initialization/prompt/discovery guards have callers that must not
recursively invoke the public Pester command. No exception is implemented.
Independent convention and fixture work can continue.

The [package-owned PSRule slice](2026-10-05-bicep-packaged-psrule.md) is qualified.
Existing registry entry points remain untouched until
a separately approved compatible release and cutover. A concise companion
technical-doc update should describe the package-owned validation boundary
in Azure-Verified-Modules-Docs after implementation is qualified.
