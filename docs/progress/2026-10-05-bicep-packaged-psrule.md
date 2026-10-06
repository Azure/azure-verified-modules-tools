# Package-owned Bicep policy defaults

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

PSRule resolves common AVM options, the security baseline, and eight YAML
definitions from the installed package. It no longer requires or reads a
consumer's `utilities/pipelines/staticValidation/psrule` directory.
Consumer Bicep sources, references, and test configuration remain local.

Source:
`Azure/bicep-registry-modules@ca00e89a931f637f628503a3a625e7d487157496`.
Options, exclusions, rule names, baseline membership, and suppression
conditions are preserved; explanatory comments were omitted.

## Checklist

- [x] Package the options and all eight policy-definition files.
- [x] Resolve and guard assets inside the installed package.
- [x] Preserve baseline selection, failure severity, tokens, and source staging.
- [x] Add a Bicep storage fixture alongside whole-module Terraform fixtures.
- [x] Exercise a copied built package without any registry utility tree.
- [x] Prove real rule execution and a meaningful native negative result.
- [x] Run the ordinary full local gate.

## Requirement map and validation

| Requirement | Native implementation | Evidence |
| --- | --- | --- |
| Default options and source selection | `Resources/bicep/psrule/ps-rule.yaml` | Configuration boundary tests reject missing assets and executable rules; consumer utility scripts are ignored |
| AVM WAF security baseline | `.ps-rule/cb-waf-security.Rule.yaml` | Real `CB.AVM.WAF.Security` execution rejects insecure transport with `Azure.Storage.SecureTransfer` |
| Dependency, minimum, unavailable-resource and module-specific suppressions | Remaining seven `.Rule.yaml` files | Preserved pinned conditions, loaded by actual PSRule in acceptance |
| Required Reliability and AVM Security; advisory Default and Security | Existing native `Invoke-PSRule` adapter | All four baselines process rules from a copied distribution |
| Caller configuration and failure propagation | Existing staging/token/result adapters | 17 unit and 21 policy component controls pass without consumer policy assets |

`.\build.ps1 pre-commit`: layout and lint passed; 3,010 unit passes with
nine skips, 1,458 component passes with one skip, zero failures. Elapsed
6m39.7s is recorded only as an observation, not a performance comparison.

`.\build.ps1 build,integration -TestName 'Integration: packaged Bicep policy*'`
built the distribution. Initial fixture failures were corrected. The final
`.\build.ps1 integration -TestName 'Integration: packaged Bicep policy*'`
passed both tests, including metadata validation, four actual PSRule
baselines, and insecure-transport rejection. TestDrive receives a copied
built package and an independent consuming repository; no source-module
import or registry checkout is used by that acceptance.

## Blockers or dependencies

No policy-slice blocker. No release, registry cutover, cloud deployment,
permission change, or host-security modification occurred. Existing registry
entry points remain unchanged pending a separately approved compatible
release and cutover.

The broader native convention/metadata migration, additional fixture curation,
and performance review remain open in
[the completion record](2026-10-05-bicep-native-validation-completion.md).
