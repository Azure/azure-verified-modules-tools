# Bicep static checks in pr-check

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Implement Bicep layout, version, changelog, and e2e source conventions in
`avm pr-check`, with root/child diagnostics. Until all required convention
checks and actual PSRule baselines are covered, both steps fail with explicit
coverage issues. Do not switch the registry's existing workflows based on this
slice.

## Pinned static-validation inventory

Compared against `Azure/bicep-registry-modules` main at
`6eb8e6ff3fe2910043d184da4192799752271ecf`. References below point to
[M: `module.tests.ps1`](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/utilities/pipelines/staticValidation/compliance/module.tests.ps1),
[D: `metadata.tests.ps1`](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/utilities/pipelines/staticValidation/compliance/metadata.tests.ps1),
and [W: `avm.template.module.yml`](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/.github/workflows/avm.template.module.yml).
The [Pester action](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/.github/actions/templates/avm-validateModulePester/action.yml#L41-L78)
runs M across the root and child scopes and module-owned `tests/unit`. M imports
D at line 378. There are 90 M assertions and two D assertions; every one is
listed below. `C` = enforced by the first, [compiled convention](2026-09-30-bicep-compiled-convention-checks.md),
or [child JSON drift](2026-09-30-bicep-child-compiled-json-drift.md) slice;
`P` = partially enforced but not equivalent; `G` = gap; `E` = pre-existing
`avm pr-check` step (metadata or Bicep transform). This table tracks cumulative
coverage; the outcome and validation below describe the first slice at completion.
Even when all `C` checks pass, `avm.bicep.convention-incomplete` makes the
convention step **fail**, rather than silently claiming complete parity.

| Source | Static compliance assertion | Coverage |
| --- | --- | --- |
| M:100 | `main.bicep` exists | C: exact regular file/case |
| M:108 | `main.json` exists | C: exact regular file/case; content is separate |
| M:116 | `README.md` exists with exact casing | C |
| M:131 | Published child is in publishing allowlist | C: validates the checkout's authoritative file on each check; missing/invalid input fails for versioned children |
| M:147 | Versioned modules have `CHANGELOG.md` | C |
| M:157 | Resource folder is singular/lowercase/hyphenated | P: naming syntax, not singularization |
| M:194 | Root version exists except on multi-scope parent | C |
| M:209 | Root has `tests/` | C |
| M:219 | Root has `tests/e2e/` | C |
| M:229 | Resource root has a waf-aligned test folder | C |
| M:239 | Multi-scope resource root has defaults (domain-service exception) | C: per scope |
| M:256 | Multi-scope resource root has waf-aligned per scope | C |
| M:280 | Multi-scope resource root has defaults per scope | C: domain-service exception |
| M:303 | Every e2e folder has `main.test.bicep` | C: exact regular file/case |
| M:318 | Required resource tests cannot have `.e2eignore` except allowlisted modules | C |
| M:354 | `.e2eignore` contains a reason | C |
| M:415 | Module workflow exists | C: regular exact-case file and parent directories per top-level module |
| M:424 | Workflow has required environment variables | C: parsed YAML, no silent absence |
| M:435 | Workflow `workflowPath` value is correct | C |
| M:452 | Workflow `modulePath` value is correct | C |
| M:469 | Workflow has required dispatch inputs | C |
| M:489 | `staticValidation` defaults to true | C: boolean default |
| M:504 | `deploymentValidation` defaults to true | C: boolean default |
| M:519 | `customLocation` has no default | C |
| M:534 | Only `main` triggers on push | C: rejects tag and additional trigger selectors |
| M:544 | Required push path filters, with metadata exclusion last | C: enforces canonical order |
| M:565 | No excess push path filters | C: also rejects duplicate patterns |
| M:585 | Automatic execution restricted to upstream repository | C: canonical condition includes cancellation; rejects weakened expressions |
| M:651 | README regeneration leaves no diff | G: `avm docs` is not proven equivalent |
| M:717 | Checked-in `main.json` matches rebuilt Bicep | C/E: convention and transform compare exact compiled bytes across root, ordinary children and `modules/` children |
| M:786 | Compiled template is nonempty | C/E: convention builds every source; transform builds modules |
| M:794 | Compiled ARM schema version is current | C: four scope schemas |
| M:818 | ARM schema reference uses HTTPS | C |
| M:827 | ARM schema, contentVersion and resources present | C/E: shared compilation guard |
| M:837 | Compiled template declares module name | C |
| M:846 | Compiled template declares module description | C: source description independent of JSON moduleDescription |
| M:858 | Required location parameter/default by scope | C: resource-group scope |
| M:872 | Telemetry parameter type/default/description | P: type/default checked; accepts both the registry's literal description and the shipped scaffold's distinct description |
| M:884 | Parameter and user-defined type (UDT) names are camelCase | C: nested properties and HCI exceptions |
| M:915 | Parameter/UDT description format | C: nested properties |
| M:939 | Conditional parameter/UDT description states condition | C |
| M:966 | Optional parameters/UDTs are not described as required | C: definition nullability |
| M:987 | Required parameter/UDT description has required/conditional prefix | C |
| M:1008 | Object and array-of-object parameters use typed schema | C: warning before 1.0, error from 1.0 |
| M:1130 | Known parameter schemas use matching AVM UDT | C: validates compiled definition references for six known names |
| M:1153 | Identity UDT has principal-ID output | C: nullable string without empty fallback |
| M:1176 | Tags parameter is nullable | C |
| M:1192 | Variable names are camelCase | C: compiler-generated names exempt |
| M:1216 | Referenced-module telemetry variable exists/is false | C: resource non-multi-scope |
| M:1240 | Telemetry deployment exists | P: required for versioned modules with resources; additionally recognizes the scaffold's prefix variable |
| M:1260 | Telemetry deployment condition is correct | C: checked for both recognized telemetry forms |
| M:1286 | Telemetry inner verbosity output | C: checked for both recognized telemetry forms |
| M:1313 | Telemetry identifier matches module identity | P: source declaration, compiled alias, JSON prefix and deployment name checked for two exact forms; registry accepts only its legacy source variable/JSON selector |
| M:1352 | Resource child-module telemetry is disabled where required | C: arrays and symbolic resources |
| M:1383 | Non-resource/multi-scope child telemetry is forwarded | C: arrays and symbolic resources |
| M:1417 | Output names are camelCase | C |
| M:1435 | Output descriptions are complete sentences | C |
| M:1458 | Location output exists when appropriate | C: README primary type, including symbolic resources; legacy path lookup missed these |
| M:1480 | Resource-group output exists when appropriate | C |
| M:1500 | Resource name output exists | C: README primary type present in compiled resources |
| M:1533 | Resource ID output exists | C: README primary type present in compiled resources |
| M:1567 | Principal-ID output exists when appropriate | C |
| M:1593 | UDT itself is not an array | C |
| M:1614 | UDT itself is not nullable | C |
| M:1636 | UDT is camelCase with `Type` suffix | C |
| M:1684 | Versioned changelog is not empty | C |
| M:1696 | Changelog header/blank lines/canonical link | C: real file casing; see note below |
| M:1722 | Changelog section for next published version | P: checks semantic headings, not target version |
| M:1757 | Changelog versions descend | C: also checks uniqueness |
| M:1773 | Exactly one `Changes` section per version | C |
| M:1810 | Exactly one `Breaking Changes` section per version | C |
| M:1847 | Changelog sections have content | C: both sections checked |
| M:1891 | `Changes` precedes `Breaking Changes` | C |
| M:1928 | Only published/pending versions in changelog | G |
| M:1990 | `version.json` is major.minor | C |
| M:2001 | Major version stays zero except NAT gateway | C |
| M:2022 | Published child increment also increments versioned parents | G |
| M:2062 | CODEOWNERS default/overrides/unique patterns | C: extra rules must be anchored outside modules |
| M:2127 | Multi-scope test references matching scope module | C: source-level declaration |
| M:2150 | Deploying test declares `serviceShort` | C: compiled resource count gates source check |
| M:2165 | Defaults test `serviceShort` ends in `min` | C |
| M:2178 | Max test `serviceShort` ends in `max` | C |
| M:2191 | Waf-aligned test `serviceShort` ends in `waf` | C |
| M:2204 | Test declares name metadata | C: nonempty literal and not commented out |
| M:2212 | Test declares description metadata | C: nonempty literal and not commented out |
| M:2220 | Deploying test declares tokenized `namePrefix` | C: compiled resource count gates source check |
| M:2235 | Deploying test directly invokes `testDeployment` | C: compiled resource count gates source check |
| M:2252 | Deployment name contains `-test-` | C: compiled resource count gates source check |
| M:2269 | `serviceShort` unique throughout repository | C |
| M:2385 | API versions are recent | G: advisory warnings in current registry |
| D:51 | Valid JSON `metadata.json` per module | E: existing metadata step; source/child parity belongs to separate slice |
| D:75 | Compiled telemetry prefix agrees with metadata | P/E: fresh compiled value checked for both source forms; transform verifies checked-in `main.json` across all discovered scopes, but literal registry source acceptance differs |

Before its assertions, M:48-60 builds/parses **every** module `main.bicep` and
discovered `main.test.bicep`. Convention now compiles each root/child module
and e2e test with the pinned Bicep CLI; failed compilation has a file-specific
error. E2e requirements use compiled resource counts rather than a source
heuristic. Convention compares the compiler's exact output bytes with each checked-in
`main.json`, including nested children under `modules/`. Transform discovers
the same scopes so `avm pr-check` reports stale or missing artifacts without
writing them, while `avm pre-commit` can repair them. Source-less metadata-only
children need no compiled artifact.

The shipped Bicep scaffold declares `avmTelemetryIdPrefix` using
`loadJsonContent('metadata.json', '$.telemetryIdPrefix')` and describes
`enableTelemetry` differently from the registry's literal checks for
`telemetryIdPrefix` and `loadJsonContent('metadata.json', 'telemetryIdPrefix')`.
The new checker accepts only those two exact source forms, verifies the matching
compiled variable, deployment name, and JSON prefix, and enforces the
condition and nested telemetry output for either form. Literal parity with
the registry remains partial and explicitly fail-closed; rejecting valid
scaffolds or claiming the old assertions unchanged would both be misleading.

The [workflow and ownership slice](2026-09-30-bicep-workflow-ownership-checks.md)
checks the same top-level module workflow declarations and repository-level
CODEOWNERS precedence as the pinned compliance suite. Workflow YAML is parsed
with exact-version powershell-yaml, loaded only for Bicep; a missing parser,
unparseable file, or absent rule produces a named failure. Trigger options,
filter ordering, condition expressions, and effective module ownership are
checked beyond the legacy substring/membership assertions so a bypass cannot
appear covered. The registry's workflows and conditions are not changed.

The [child publishing slice](2026-09-30-bicep-child-publishing-allowlist.md)
loads the checked-in registry allowlist when a discovered child has
`version.json`; it does not embed or infer a list. Missing, mis-cased,
linked, malformed or unreadable input fails with a named issue, while
unversioned children need no allowlist.

The M:1696 assertion requests `Changelog.md` in its link, but actual registry
files and this repository's generated changelogs use `CHANGELOG.md`. The new
rule checks the real canonical casing; retaining the literal assertion would
reject valid published modules.
The existing Bicep [transform engine](../../src/Avm.Authoring/Engines/Bicep/Invoke-AvmBicepTransform.ps1)
and [compiled-template guard](../../src/Avm.Authoring/Engines/Bicep/Get-AvmBicepCompiledJson.ps1)
provide the three `E` ARM-template checks above when that step runs; the
convention engine now also uses that guard and implements compiled assertions.

The [test-file selector](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/.github/actions/templates/avm-getModuleTestFiles/action.yml)
chooses defaults and waf-aligned sources. The
[PSRule action](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/.github/actions/templates/avm-validateModulePSRule/action.yml#L38-L135)
replaces tenant/subscription/management group, name-prefix, local and custom
tokens across test sources **and their referenced files** before evaluating
rules. Its [configuration](https://github.com/Azure/bicep-registry-modules/blob/6eb8e6ff3fe2910043d184da4192799752271ecf/utilities/pipelines/staticValidation/psrule/ps-rule.yaml)
expands Bicep, applies suppression rules, and excludes selected global rules.
The [PSRule evaluation slice](2026-09-30-bicep-psrule-policy-evaluation.md)
uses the target repository's matching configuration and `.ps-rule/` directory
with exact-version PSRule modules. It stages tokenized selected sources and
transitive local references outside the checkout, then verifies that each
baseline produced inspectable results for expanded Azure resources. Missing
config, tool, token, local reference, baseline, or output fails; a required
rule violation is an error, and an advisory violation is a warning. It does
not make the other convention gaps pass.

| Source | PSRule baseline and result in registry | Coverage |
| --- | --- | --- |
| W:63 | `Azure.Pillar.Reliability`, required | C: evaluated on staged tests; rule failures are errors |
| W:65 | `CB.AVM.WAF.Security`, required | C: repository custom baseline; failures are errors |
| W:93 | `Azure.Default`, advisory | C: evaluated; rule failures are warnings |
| W:95 | `Azure.Pillar.Security`, advisory | C: evaluated; rule failures are warnings |

PSRule 2.9.0 and PSRule.Rules.Azure 1.47.0 are exact, optional Bicep-only
dependencies; the registry's own action resolves its package version
independently. Real local evaluation exercised all eight baseline/test
combinations using these versions and the pinned Bicep compiler. The registry
workflow's fork-safe conditions and publication/deployment gates are unchanged.
Module-owned `tests/unit` execution belongs to the separately reviewed Bicep
test-tier slice, not convention. JSON `moduleDescription` and Bicep source
description are independent; this slice does not edit either validation rule.

## Follow-up before registry migration

The [compiled convention slice](2026-09-30-bicep-compiled-convention-checks.md)
covered e2e compilation and compiled-template assertions. Complete
publication-aware versions and changelogs, resource-folder singularization,
README drift, and
advisory API-version checks. Reconcile the scaffold telemetry form with
registry's literal assertions. A separate publication-aware slice must use authoritative
MCR tags without inventing local published-version history. The coverage
ledger above is the per-assertion handoff; these are not implicit passes. Preserve the current
fork-safe and static-validation workflow conditions during any later cutover.

## Checklist

- [x] Inventory the registry's static compliance and PSRule checks at a fixed revision.
- [x] Implement a self-contained Bicep static-check slice with actionable results.
- [x] Cover passing and failing module fixtures, including required-check failures.
- [x] Independently review the implementation and address findings.
- [x] Run `./build.ps1 pre-commit`, commit, push, and open a review.

## Validation

Focused `./build.ps1 pre-commit -TestName ...` passed layout, lint, 23 unit
tests, and 18 component tests. The complete 90+2 assertion inventory was
checked against the pinned source line numbers. The first full gate exposed
CRLF in five new PowerShell files; those files were normalized to UTF-8
without BOM and LF, and the targeted encoding tests passed. A second full
gate was stopped when independent review found two bugs; both were fixed and
covered by the focused gate. The final unfiltered `./build.ps1 pre-commit`
passed layout, lint, 1,904 unit tests (nine skipped), and 929 component tests
(none skipped). It emitted 49 warnings from exercised negative-path tests.

Independent review caught a missed `modules/` child scope and conditional
`module testDeployment ... = if (...) {` declarations. The engine now discovers
module-directory children, accepts conditional declarations, and exercises
both cases in the component suite.

## Blockers or dependencies

Bicep metadata/source validation is in separate [tools #201](https://github.com/Azure/azure-verified-modules-tools/pull/201),
which removes source/JSON description equality and handles source-less
metadata-only scopes; the independent Bicep test tiers are in
[tools #202](https://github.com/Azure/azure-verified-modules-tools/pull/202),
where module `tests/unit` runs by default and legacy compliance remains
opt-in until convention parity. This branch has not copied or changed their
files. Real-module `avm pr-check` smoke
should be revisited after the metadata change merges and this branch is
updated from main, before any final CI cutover. The registry catalog still
enforces published source-pending status; local `avm pr-check` does not replace
that separate gate. Registry workflow migration, deployments, and releases
are out of scope.
