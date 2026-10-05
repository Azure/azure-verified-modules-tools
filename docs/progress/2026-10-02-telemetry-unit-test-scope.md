# Telemetry migration for explicit unit-test targets

**Status**: in-progress
**Started**: 2026-10-02
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Preserve existing unit-test targets and assertions during central telemetry
migration. Establish which local delegated runs can be migrated safely
without weakening the safeguards for unknown dependencies or real providers.
The original implementation passed all-platform CI and local ALZ qualification.
Its plan-only workflow preview reached the selected ALZ repository but
stopped at a BAMI test-tenant group lookup before telemetry migration.
The merged prerequisite repairs passed local and hosted qualification.
Final safety inspection identified automatic state-lock recovery in plan-only
execution; its approved repair and the single ALZ preview remain outstanding.

## Checklist

- [x] Identify an active, published repository with existing delegated tests.
- [x] Reproduce the unsupported scope locally without Azure access.
- [x] Identify affected provider mocks and the generated location contract.
- [x] Add native Terraform-test support to MaPoTF before extending Tools rules.
- [x] Validate draft consumer rules against an explicitly identified source build.
- [x] Verify the released MaPoTF distribution and signed checksum manifest.
- [x] Implement and test only source-proven migration cases.
- [x] Run the full local gate.
- [x] Complete the full telemetry integration run, commit and push.
- [x] Fix and qualify standalone test-module discovery in hosted integration.
- [x] Preserve all eight ALZ unit plans through the complete local pre-commit chain.
- [x] Verify second-pass transformation stability without retained changes.
- [x] Attempt the ALZ plan-only preview and classify its pre-migration failure.
- [x] Integrate the merged repository-sync prerequisite fixes and qualify locally.
- [x] Pass hosted qualification on the combined source.
- [ ] Make plan-only state-lock handling non-mutating and qualify the repair.
- [ ] Complete the narrow ALZ networking preview after its identity prerequisites pass.

## Evidence

`Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet`
is active and published. Its main at
`670c45d48b0c7c6a244cddac8715269b0fc06185` includes three genuine unit-test
files. Firewall public-IP tags and BGP-propagation tests use
`module { source = "./modules/hub-virtual-network-mesh" }`; primary-region
selection tests target the root. All retain authored telemetry opt-outs.
The current mock migrator explicitly rejects delegated run modules, so a
remote dispatch would not yet provide useful additional evidence.

Locations are supplied inside hub objects. Check the migrated root and child
input contracts before deciding whether tests need another location value;
do not alter the authored per-hub locations or invent production defaults.

A controlled real-MaPoTF regression reproduced the delegated-run rejection
with one root run and one local-child run, provider mocks, authored telemetry
opt-outs and different hub regions. It failed at the current explicit scope
guard before any Terraform test execution or Azure call. The regression is
preserved as the session artifact `telemetry-unit-scope-regression.patch`,
outside committed test discovery until its native prerequisite exists.

Both real root and child metadata declare telemetry prefixes. Neither
inspected `variables.tf` declares a standalone location input. The generated
telemetry contract requires one, so migration must handle test inputs as well
as provider mocks without overwriting the authored hub regions.

The requester selected native Terraform-test support in MaPoTF rather than
a larger HCL text-rewriting layer in Tools. Released MaPoTF 0.2.2 indexes
standard Terraform root block kinds, not test runs, global test variables
or mock-provider blocks. Source work is isolated in the MaPoTF project,
starting from main `aa6f5045d34bccc772f115a3198b2aa98e87bf32`.
The Tools production pin remained unchanged during development-candidate checks.

The agreed native interface is opt-in single-file selection:
`transform --tf-dir <owner> --test-file <relative.tftest.hcl>`.
Only the selected file may change; normal Terraform discovery stays unchanged.
`data "test_file"` exposes file identity, runs, mock providers and explicit
root/local/remote run targets. The existing `module_source` data source can
inspect known local target declarations without provider initialization.
The planned `debug --eval <expression>` option returns one JSON value without
applying transforms. Tools will use a before-migration declaration snapshot,
so an authored location or unrelated pre-existing missing input is not
silently replaced. These capabilities were first qualified in a development candidate and are
now available in the verified 0.3.0 release. Tools integration is in progress.

## Native implementation and consumer validation

[Azure/mapotf#133](https://github.com/Azure/mapotf/pull/133) implements the
native interface. Runtime implementation commit:
`25775cf91ea010b5f1ed363b2b543e2a71e9cf0f`. Follow-up
`7c1ad9b85848938df37faca06922d2f55f499796` changes documentation/tests to
clarify repeated variable flags; runtime files are unchanged.
The operator merged the review on October 2 at
`d7485208e513b7b29d9128c6fe25a09864ba96ac` and confirmed the release
version will be 0.3.0.

The native repository's build, tests, vet and lint passed. Hosted Windows
and Linux builds and CodeQL completed successfully at both `25775cf` and
the final `7c1ad9b` head:
[build](https://github.com/Azure/mapotf/actions/runs/37009035845) and
[CodeQL](https://github.com/Azure/mapotf/actions/runs/37009035915).
Those checks completed before the operator's merge.

Tools-side development checks used `./build.ps1 integration` with an explicit,
commit-identified executable, never a replaced verified cache entry:
SHA-256 `D7F8F63B899D7FC45B2E057744F05DE4720B949C503D05A565C12C799418B8B8`.
Seven consumer cases passed with raw argv and the same seven passed with a
variable file, with zero failures or skips. They verify non-writing
inspection, before/after input declarations, selected-file isolation,
authored regions and opt-outs, reserved-name inputs, explicit global
string/null/expression values, per-run overrides and second-pass stability.
No Terraform provider initialization or Azure request was involved.

The first consumer run exposed Cobra's CSV handling of quoted list arguments.
The native fix preserves one complete value per flag occurrence and splits
assignments only at the first equals sign. Both input methods were rechecked
without weakening the preservation assertions.

The inspection/location profiles and exact passing consumer tests remain
session artifacts under `native-unit-tests/`. The temporary consumer test was
removed from repository test discovery after its source was preserved.
Those development checks did not change the released Tools pin or runtime.

## Released dependency and Tools integration

[MaPoTF 0.3.0](https://github.com/Azure/mapotf/releases/tag/v0.3.0) is final,
with all six Tools platform archives and the checksum manifest. The
[checksum signing run](https://github.com/Azure/mapotf/actions/runs/37015208684)
completed successfully. Local cosign verification returned `Verified OK`
against the exact release-tag workflow identity and GitHub OIDC issuer.
The checksum manifest SHA-256 is
`AB85F298F7A3BB74684B1D5A8B0712B1812C23E0491EF194C234CAF5129A242C`.

The standard pin updater changed only MaPoTF from 0.2.2 to 0.3.0. All six
hashes match the signature-verified manifest. Normal tool resolution installed
release 0.3.0 at source commit `d7485208e513b7b29d9128c6fe25a09864ba96ac`;
no development binary was substituted into the verified cache.

The initial Tools integration snapshots native test targets and local input
declarations before ordinary source transforms, then adds only newly required
location inputs to eligible mocked runs. Authored global and per-run inputs
remain untouched. The root/local-child Terraform regression is restored.
Focused checks, the full local gate and all 34 telemetry/native integration
cases passed. Runtime commit `db16bbfc239d2f6f46d79e9f75af9e0079c25ed3`
is pushed. Hosted qualification found a standalone test-target regression,
subsequently fixed and qualified in
`9e1595a9abd6cb0a5a17fea8b9f01c76ae2a2656`. The ALZ workflow preview remains
outstanding.

## Integration validation

- 99 focused unit tests passed, including native inspection and migration
  decisions, sibling-target random dependencies, provider guards and cleanup.
- Nine Terraform end-to-end component tests passed with the process stub
  accepting only its known empty test fixture.
- The first complete integration run passed 32 of 33 cases. Its sole failure
  was native inspection of a helper test file with no runs: an empty
  `for_each` does not create a `module_source` category. Inspection now projects
  the explicit target directory set instead of assuming that category exists.
  A new regression covers the empty set without hiding malformed JSON.
- The subsequent focused integration run passed all 14 selected cases,
  including the earlier failure, all 12 native-profile cases, and actual
  Terraform root/child runs. It checks first-pass drift restoration and native
  backup cleanup, second-pass stability, selected-file isolation, preserved
  expressions/nulls/regions, and explicit rejection of unknown/remote targets.
- The delegated Terraform fixture now initializes with the same
  `-test-directory` as test execution, matching the existing AVM runner.
  Both actual provider-mocked runs pass without Azure calls.
- Full `./build.ps1 pre-commit`: layout and lint passed, 2,689 unit tests
  passed (nine skipped), and 1,291 component tests passed (one skipped).
  Zero test failures; the gate completed in 16m31s.
- The final complete telemetry/native integration run passed all 34 cases,
  with zero failures or skips.

## Hosted standalone test-target regression

The [macOS real-binary job](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37029558799/job/110912670057)
completed with 156 passes, three failures and one skip. Native inspection
rejected the real-binary fixture under `/var/folders/...` as an unknown local
target. The first hypothesis was a macOS directory alias, but the completed
Windows and Linux jobs reported the same failure. Source-only reproduction
against both actual CI fixtures confirmed the cause: the orchestrator supplied
only root and child modules to native inspection, omitting its already
discovered standalone `tests/wrapper` and `tests/unit/setup` targets.

The repair includes these known standalone test modules in inspection and
migration, without making them owners of nearby test files. Only root and
child module profiles establish file ownership, so a `.tf` file in
`tests/unit` cannot prevent its sibling unit test from being inspected.
The explicit directory allowlist and provider-review guards remain unchanged.
The provisional alias-rebinding implementation was removed rather than
retaining an unproven workaround.

Both added fixture regressions first reproduced the hosted failure, then
passed the real transform with no drift and unchanged test-file hashes.
A directory-junction regression also passes without path rebinding and
checks native selected-file migration, second-pass stability and cleanup.
The corresponding 100 unit cases and all 37 telemetry/native integration
cases pass, with no failures or skips. The complete integration run finished
in 7m24s. The first full-gate attempt exhausted the documented transient
PSScriptAnalyzer crash retries. A fresh-process `./build.ps1 pre-commit`
passed layout and lint, all 2,690 unit tests (nine skipped) and all 1,291
component tests (one skipped). It finished in 14m08s with zero errors.
The [hosted qualification run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37037370527)
at `9e1595a9abd6cb0a5a17fea8b9f01c76ae2a2656` completed successfully.
All eleven validation jobs passed: lint, workflow tests, the three OS test
jobs, and both real-binary fixtures on Windows, Linux and macOS. Coverage
upload and test-result publication also passed. Completed job logs confirm
the previously failing pre-commit case, both fixture regressions and the
directory-alias regression actually executed and passed.

The narrow preview was initially blocked. A concurrency check found
the [scheduled repository sync](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37009330644)
still queued and a [second sync](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37036072558)
pending. Monitoring left those runs unchanged. The later preview below was
dispatched only after every active and pending sync state was empty.

A disposable local ALZ networking clone at `670c45d48b0c7c6a244cddac8715269b0fc06185`
transformed successfully: 74 files processed, 30 changed, no reported issues.
Before migration, its three authored test files
contain eight runs, all `command = plan`, with AzAPI, AzureRM, modtm and random
mocks and no real-provider declarations or setup/teardown hooks. The original
native inspection is retained before transformation. Comparing the native
before/after records confirms all eight targets, commands, assertions,
expected failures, authored variables, per-hub regions and telemetry opt-outs
are preserved. Only the new test-only location and standard mock migration
change their test contracts.

The first local unit invocation stopped during dependency initialization,
before any run executed: nested Git module downloads hit Windows
`fatal: '$GIT_DIR' too big` under the long disposable checkout path.
Moving the unchanged clone to the shorter ignored `out/alz` path resolved
the download failure without source repairs or reduced coverage. All eight
original unit plans then passed. A separate second-pass `-CheckDrift`
processed 74 files with zero changes and no issues.

The complete local `avm pre-commit` chain passed all six steps: metadata,
managed-file sync, convention checks, transformation, formatting and
documentation. It retained the repository's managed-files 1.1.0 pin; the
1.1.2 availability warning was nonblocking and no upgrade was requested.
Repeating the unit tier after this preparation again executed all eight
original runs across three files: eight passed, zero failed, no issues.
Azure credentials and CLI/managed identity/OIDC authentication were disabled
for both local mocked runs. All local qualification jobs are finished.

## Plan-only preview and identity prerequisite

The documentation-only checkpoint at
`ef039737116c52cf3af6822aeb6e875a4f524618` also passed its complete
[CI recheck](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37047130289):
all eleven validation jobs, coverage upload and test-result publication.
Both CI watchers are finished; no local qualification job remains running.

On October 3, all five active workflow-state queries and the exact-head
duplicate check returned zero. The
[ALZ-only preview](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37110789089)
was dispatched once at that qualified Tools head with `plan_only=true`,
workflow authoring source enabled, managed-file forcing disabled and project
sync disabled. The active, unarchived ALZ main remained
`670c45d48b0c7c6a244cddac8715269b0fc06185`. Matrix generation selected only
the intended ALZ repository.

Preparation failed in the BAMI candidate identity plan:
`module.azure.data.azuread_group.entra_readers` could not resolve
`grp-sec-avm-tf-end-to-end-testing-entra-readers`.
`Invoke-RepositorySync.ps1` invokes this prerequisite before authoring
preparation, and `TestTenant.ps1` terminates on the failed Terraform plan
without state repair or an automatic apply retry. No telemetry migration or
module test ran in this preview. It produced no candidate or validation
artifact; validation and publication were both skipped.

The [same ALZ job on main](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37062290942/job/111080590663)
at `b0ba22f2fca81e4e068414e7f20bb703acd37de4` had already failed with the
identical group lookup error. This is a shared identity prerequisite, not
evidence of a telemetry transformation regression. The repository-sync
README records that the group exists in BAMI but controller lookup and
membership readiness were unproved. The failure alone does not establish
whether the group is absent or inaccessible to the configured controller.
No group, permission, tenant selection, state or workflow guard was changed,
and the failed preview was not retried.

## Resumed qualification

On October 5, the operator reported that group membership should now be
corrected and explicitly approved resuming ALZ-only qualification. The scope
is to bring the merged prerequisite fixes from main into this feature branch,
revalidate the combined source, and run one ALZ networking plan-only preview
after checking workflow safeguards and existing runs. No apply, access
change, publication, protected approval or merge to main is authorized.
The membership report is not yet controller-authenticated lookup evidence.

The group-name consumer migration in
[#218](https://github.com/Azure/azure-verified-modules-tools/pull/218)
and refreshed Terraform data evidence fix in
[#222](https://github.com/Azure/azure-verified-modules-tools/pull/222)
are now on main. The October 3 preview used the older source, so its retired
group-name failure remains historical evidence rather than a claim about
the repaired source.

Main `a55f79c63e45fd0f141ffb2cd43eea5cad3522f0` is integrated without
discarding the feature branch's separate prepare, validate and publish jobs.
The reusable execution workflow now passes only BAMI provider settings and
the independent backend configuration. Retired provider variables and removed
script arguments are no longer forwarded. Both trusted-main apply restrictions
and manual branch plan-only support remain intact. The candidate guard still
stops on any managed identity change; this preview cannot apply a prerequisite.
Refreshed prior-state evidence and configured group membership checks are retained.
Main's Bicep and offline metadata-validation changes are also preserved.

The CI timeout merge retains 30 minutes for Windows and main's 25-minute
budget elsewhere. The first local gate found two tests still expecting the
pre-merge timeout definitions. Their expectations now explicitly check the
combined expression rather than relaxing the workflow contract.

Local requalification:

- Focused repository-sync checks passed 74 unit and 113 component tests.
- Both CI timeout contracts and the other selected workflow checks passed:
  seven tests, no failures or skips.
- The final `./build.ps1 pre-commit` passed layout, lint, 3,043 unit tests
  (nine skipped) and 1,308 component tests (one skipped), with zero failures.
  Lint recovered through its existing transient analyzer retries.
- The native telemetry, test-migration and saved-plan evidence selection
  initially passed 37 of 39 cases. Two no-cloud fixtures could not construct
  an AzAPI credential after all authentication sources were disabled.
  Both passed when rerun with deliberately invalid synthetic provider settings,
  while CLI, managed identity and OIDC authentication remained disabled.
  All 39 distinct cases are covered, without skips, real Azure credentials
  or cloud state. No production code or test assertion was changed for this.
- `./build.ps1 test-tenant-terraform` passed all 31 provider-mocked cases:
  13 root, four candidate and 14 Azure-module cases. Backend initialization
  was disabled. The disposable retired-state fixture produced exactly seven
  forget actions and no refresh, read or destruction; the actual mocked
  candidate plan passed the configured membership and federation guard.

Logs are retained under `out/telemetry-prerequisite-*.log`. The telemetry
engine, MaPoTF profiles and tool pins are unchanged by this integration.
The active, unarchived ALZ main still matches the previously qualified
`670c45d48b0c7c6a244cddac8715269b0fc06185`, including its eight authored
mocked plans. Its relevant example hook only changes staged tfvars locally.
All eight required BAMI environment settings are populated; the configured
tenant, controller and admin subscription match the repair handoff.
These configuration reads are not controller-authenticated group lookup.
No preview has been dispatched under the new approval yet.

### Hosted package-import assertion

The merged source at `b724ab9b64fb27337e5830dc1d9e33ac51d829b3` reached
[hosted qualification](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37281506575).
All six integration jobs, Windows and Ubuntu test jobs, lint and workflow
tests passed. The macOS test job failed one package-import component assertion:
`Get-Module` returned both the already loaded source version and the selected
test package. The helper had imported the correct package; the test incorrectly
required it to be the only loaded version. Coverage upload was skipped and
test-result publication completed. The workflow is finished and was not retried.

Preloading a second synthetic module version reproduces the same failure
locally. The assertions now inspect the module behind the active exported
command, while explicitly retaining the other loaded version. The missing
source-manifest check and both wrong-package/escaped-definition rejection
checks remain. All four focused component cases pass. No production code,
package-import helper or telemetry behavior changed. The subsequent full
`./build.ps1 pre-commit` passed layout, lint, 3,043 unit tests (nine skipped)
and 1,308 component tests (one skipped), with zero failures. The reproduction,
focused result and full gate are retained in `out/telemetry-package-import-*.log`.
New-head hosted qualification must still pass before the approved preview.

### Plan-only state-lock handling

The repair at `c7e22cd12e4118e47c480f23e73d8d4f098dc182` passed its entire
[hosted qualification](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37284621815):
all thirteen jobs and all nineteen current-head checks succeeded.
The target source and BAMI configuration still matched the qualified inputs.

Final safety inspection found that common repository Terraform initialization
and planning still enabled automatic state-lock recovery in plan-only mode.
Unlike the BAMI candidate helper, that path could run `terraform force-unlock`
or break the storage lease after a lock error. No preview was dispatched.
The operator explicitly approved repairing plan-only runs to leave those
locks untouched and fail clearly, then requalifying before the single preview.
Non-plan execution must retain its existing recovery behavior.

The preview flag now reaches both initialization paths and the ordinary
repository plan. Those calls disable the retry helper's state-lock recovery
actions, leaving the original error visible. Non-plan recovery and ordinary
provider-download retries are unchanged. Four mocked acquisition/release
failures reproduced the unwanted recovery before the change; all now fail
without an unlock or lease-break call. Focused qualification passed 27 unit
and 55 component tests, including actual driver propagation of both modes.
The full local gate passed layout, lint, 3,055 unit tests (nine skipped) and
1,308 component tests (one skipped), with zero failures. Its first attempt
hit a Windows access-denied error while moving an unchanged clone fixture.
All fifteen clone cases then passed in isolation, followed by the complete
gate, without changes to that source or its tests. Evidence is retained in
`out/telemetry-plan-only-lock-*.log`. New-head hosted qualification remains
required before the preview.

## Blockers or dependencies

Remote qualification still needs evidence that the configured BAMI
controller can resolve the required groups using the repaired source.
The approved preview may verify this without changing access. Do not bypass the identity guard,
invent a replacement group, grant permissions or switch to the legacy tenant
to make telemetry qualification pass.
Investigation used existing workflow logs and local source only. Archived repositories remain excluded.
No deployment, module publication, protected approval, or source-module repair
is authorized by this slice.
The MaPoTF release dependency is satisfied. Release creation, approval and
publication remained operator-owned; this session verified the published
distribution and attestation without changing either. Existing direct-unit
migration remains qualified by the preceding local gate, all-platform CI and
active-pattern preview.
Before rollout, the team documentation should describe the approved release,
test-migration behavior and upgrade procedure, reusing an existing open
documentation review where applicable. The current check could not enumerate
those reviews: the GitHub Enterprise CLI returned HTTP 401 and the Edge
fallback reached the single-sign-on page. No login or account change was made.
