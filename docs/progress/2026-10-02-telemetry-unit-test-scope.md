# Telemetry migration for explicit unit-test targets

**Status**: blocked
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Preserve existing unit-test targets and assertions during central telemetry
migration. Establish which local delegated runs can be migrated safely
without weakening the safeguards for unknown dependencies or real providers.
Implementation and local ALZ qualification are complete. The remaining
plan-only workflow preview is blocked by existing repository-sync runs.

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
- [ ] Repeat the narrow ALZ networking preview.

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

The narrow preview has not been dispatched. A fresh concurrency check found
the [scheduled repository sync](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37009330644)
still queued and a [second sync](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37036072558)
pending. Wait for all active and pending sync states to clear before the
already-authorized narrow plan-only preview. Do not replace either slot,
cancel either run or retry it.

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

## Blockers or dependencies

The sole remaining qualification blocker is workflow concurrency: wait for
the existing scheduled and pending repository-sync runs, then verify the
ALZ-only plan-only preview without publication.
Investigation is local and source-only. Archived repositories remain excluded.
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
