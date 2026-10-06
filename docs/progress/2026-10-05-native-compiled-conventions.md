# Native compiled Bicep conventions

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Replace compiled-template, parameter, variable, telemetry and output checker
functions with individually reported native Pester requirements. Preparation
only parses source and compiled data; the packaged tests own assertions.

## Checklist

- [x] Migrate compiled requirements and remove their obsolete checker functions.
- [x] Translate native diagnostics and preserve advisory severity.
- [x] Compare the pinned registry requirements and retain negative controls.
- [x] Verify native metadata/telemetry agreement and checked-in JSON drift.
- [x] Run the full gate, commit, and push.

## Requirement map

Original line ranges refer to `utilities/pipelines/staticValidation/compliance/module.tests.ps1`
at registry commit `ca00e89a931f637f628503a3a625e7d487157496`.
All new assertions below live in packaged `conventions/Compiled.Tests.ps1`.
The complete root/child fixture is the common positive control; focused positive
and negative controls are in `BicepConvention.Component.Tests.ps1` and
`NativeCompiled.Component.Tests.ps1`. The latter retains all eleven former
compiled-rule unit cases, now invoking the real packaged framework, and adds
separate name/description negatives.

| Original requirement | Native cases | Positive and negative evidence |
| --- | --- | --- |
| Compiled artifact matches source (717-752) | Checked-in template present; exact compiler-output bytes | Nested modules pass unchanged, then stale and missing artifacts fail without rewriting them. |
| Nonempty ARM template, current schema, HTTPS, required fields (786-835) | Current deployment schema; HTTPS; required ARM elements | Complete fixture; invalid schema; each missing `$schema`, `contentVersion`, `resources`. Compiler preparation also rejects structurally invalid output before convention execution. |
| Compiled metadata name and description (837-854) | Separate nonempty name and description | Complete fixture; invalid metadata on root and child source paths. |
| Resource-group location default (858-869) | Resource-group or global location default | Complete fixture; invalid location default. |
| Parameter/property names, category sentences, conditional and required descriptions (884-1005) | Six independently reported cases per parameter/UDT property | Complete fixture; child parameter and UDT violations. |
| Explicit object/array-of-object types (1008-1060) | Explicit object, UDT or resource-derived type | Typed fixture; untyped objects warn before 1.0 and fail at 1.0. |
| Common AVM parameter references and nullable tags (1063-1187) | Per-common-parameter UDT reference; nullable tags | Complete fixture; child common-interface and tags violations. The original common-interface assertion checks `$ref`, not an external schema. |
| Variable names and compiler-generated aliases (1192-1213) | One camelCase/`$fxv#N` case per variable | Compiler alias positive; invalid standard variable name. |
| Telemetry opt-out and deployment presence (872-882, 1240-1257) | Standard opt-out parameter; telemetry deployment for versioned resources | Root and versioned-child positives; absent deployment and string rather than Boolean defaults. |
| Telemetry condition and information output (1260-1310) | Separate cases for every telemetry deployment | Versioned-child positives; child condition/output mismatches with child-specific paths. |
| Metadata prefix, one-level alias, deployment name and source wiring (1313-1349) | Regular/strict metadata; nonempty prefix; metadata equality; prefix-first name; source reader; no literal; no conflicting readers | Both approved source forms and descriptions; direct/aliased/concat positives; mismatched alias, spoofed or conditional name, missing metadata, commented declarations, literal prefixes and mismatched descriptions fail. |
| Child telemetry suppression and forwarding (1216-1235, 1352-1411) | Boolean suppression switch; per-child forwarding | Symbolic resource and pattern positives; missing/incorrect forwarding and string false fail; multi-scope exception retained. |
| Output names and descriptions (1417-1455) | Separate naming and description cases per output | Complete fixture; output drift negative. |
| Primary resource name, ID, location and resource-group output (1458-1564) | README primary type; name; resourceId; per-primary location; resourceGroupName | Complete fixture and symbolic resource location positive; missing outputs and wrong location references fail. |
| Supported system-assigned principal ID (1153-1173, 1567-1588) | Nullable string principal ID without empty-string fallback | Complete fixture; managed-identity/child UDT violations retain required output behavior. |
| UDT array/nullability/name (1593-1660) | Independent schema, non-array, nonnullable and Type-suffix cases per definition | Complete fixture; child UDT violations. |

The four old compiled checker functions are deleted. Parsing, compiler invocation,
source preparation and result translation remain ordinary implementation helpers.
Native assertion warnings retain their public severity; a runtime exception or
unexpected skip carrying a warning tag is still an error. An unrelated warning
cannot conceal an unreported failed test. Applicable data-driven cases are
declared only for nonempty inputs, preserving Pester 6's fail-on-empty default.

## Validation

- Full `build.ps1 pre-commit` with Pester 6.2.0: 3,001 unit passed / nine skipped;
  1,497 component passed / one skipped; layout and lint green.
- Pester 5.7.1 native/convention compatibility: 153 passed / one skipped.
- Five real compiler/scaffold integration cases pass with Pester 6.2.0, including
  both source forms and bad description, literal prefix and non-prefix-first name.
- Seven copied-package metadata/PSRule cases pass with Pester 5.7.1 and 6.2.0.
- Earlier analyzer crashes were retried through the existing build gate, not
  waived. Three false-positive Pester BeforeAll variable findings have targeted
  suppressions; their values are consumed by native It blocks.
- Observed full gate was 9m10s. This is not an equivalent-work performance claim.
- Hosted failures on prior head `248b096` are corrected in the companion
  `2026-10-05-native-validation-hosted-fixes.md` slice. New hosted evidence remains
  a prerequisite to final overall handoff.

Other convention families and unit-compliance portability remain in the overall
completion record. No cloud execution or registry cutover. Workflow migration is
separately owned and preserves the current module caller contract.
