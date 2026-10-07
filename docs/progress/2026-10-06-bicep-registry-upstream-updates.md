# Bicep registry upstream updates

**Status**: in-progress
**Started**: 2026-10-06
**Updated**: 2026-10-07
**Branch**: `jaredfholgate-bicep-upstream-alignment`

## Outcome

Compare the registry's workflow and tooling changes since the incorporated
baselines, adopt confirmed gaps in the existing tools workflows and
Avm.Authoring, and qualify the result without Azure execution or registry
cutover locally. The user separately approved the existing Azure-authenticated
hosted CI matrix on 2026-10-07.

## Baselines

- Tools base: `d14117248e085baa80fb608b97c93e3c3619b90e`, the merge of
  [#229](https://github.com/Azure/azure-verified-modules-tools/pull/229).
  The clean feature branch, local `origin/main`, and independently queried
  GitHub `main` all matched before source investigation.
- Registry workflow/deployment baseline:
  `89b1910d5d11e4f87579ae98e119effe9b7c9578`, recorded in the
  [workflow parity slice](2026-10-02-bicep-workflow-parity.md).
- Registry native validation/PSRule baseline:
  `ca00e89a931f637f628503a3a625e7d487157496`, recorded in the
  [native validation slice](2026-10-05-bicep-native-validation-completion.md).
- Pinned registry head: `6001a5b529e3e6490c0b63323fb60b9e069ffd9d`
  (2026-10-06 21:41:22 UTC). The complete comparison from the older baseline
  contains 18 commits and 120 changed paths, below GitHub's file-list limit.
  Seven commits follow the native-validation baseline.

## Checklist

- [x] Read the agent contract and active/blocked work records.
- [x] Confirm the fresh current-main base and check for an overlapping review.
- [x] Pin upstream head and establish both incorporated baselines.
- [x] Inspect actual changed workflows, their tooling, and dependency pins.
- [x] Map all relevant changes to adopted, already covered, or excluded behavior.
- [x] Implement applicable gaps with focused positive and negative regressions.
- [x] Run the full local gate, Bicep native acceptance, and shared regressions.
- [x] Commit, push, and open the new review.
- [ ] Complete hosted checks, including the Windows job-timeout correction.

## Comparison evidence

The complete immutable GitHub comparisons and individual changed-file patches
are retained in the session artifacts. The comparison includes the actual
workflow, action, script, and regression-test changes, rather than commit
subjects alone.

| Upstream change | Disposition in tools |
| --- | --- |
| Typed timeouts reading provider/location metadata (`8c50b66`) | Adopt buffered, three-attempt reads with permission/cancellation precedence and the existing retry mechanism. |
| ACI, ML/Cosmos and AKS empty-zone capacity evidence (`a7edc52`) | Adopt narrowly scoped classifiers, including selected-region/subscription context and malformed/mixed negative controls. |
| Confirmed transient deployment failures (`a7edc52`) | Adopt cleanup-before-same-region replay for the three named resource types; prohibit deployment scripts and retain existing safe in-place retries. Classification/read failures must not silently enable replay. |
| Nested preflight rejection and existing Graph lookup (`a7edc52`) | Adopt exact child-record absence and server-exported existing-declaration proof. Ordinary missing or ID-less Create operations remain failures. |
| Accepted asynchronous history deletion (`a7edc52`) | Adopt exact response checks and persisted root deletion progress for cleanup-only recovery, without relaxing root/case ownership or replay safety. |
| Static `builtInServicePrincipalObjectId` default (`a7edc52`) | Adopt in packaged PSRule options and verify with installed-package analysis; never replace deployment parameters. |
| Latest Bicep used by upstream bootstrap | Update the verified six-platform pin from 0.47.16 to 0.48.1. Adapt the removed docs `--template-file` option to native config selection: explicit canonical configs render directly; package defaults use one temporary source/config copy per resolved root, never caller writes. Reviewed the October 5 release notes, including docs configuration/errors, trusted clouds, nullable-existing language version and compilation-error exit codes. |
| Pester, PSRule and YAML setup | Retain central Pester 5.7.1, PSRule 2.9.0, PSRule.Rules.Azure 1.47.0 and powershell-yaml 0.4.12. The PSRule versions match current stable releases; upstream Pester/PSRule setup floats rather than introducing another exact pin. |
| Subscription matrix, deployment-only/shared-scope locks, publication locks (`1ea4789`, `b55b7a5` and surrounding workflow changes) | Registry caller responsibility: preserve in the migration contract. Tools has no Bicep reusable deployment caller to patch; do not introduce a premature cutover. Explicit subscription selection already stays fixed through native execution and cleanup. |
| Both experimental labels and ignored-job early exit (`150c7f6`, `b55b7a5`) | Registry orchestration requirement. Native ignored cases already short-circuit before tool/Azure work; document the two-label caller gate without enabling deployments. |
| Failed-job retry regex (`75ba30c`) | Registry-specific retry utility. Tools' workflow creates/updates failure issues with Actions read-only permission; it does not rerun jobs. |
| Timeout observation, structured operation pages, complete regional cleanup (`9dea670`, `7c31eb8`) | Already incorporated in native deployment/watch/discovery and strict cleanup. Extend those implementations rather than importing legacy scripts. |
| Required subscription features (`4674e0b`, `a7edc52`) | Generic exact-module-path feature handling already exists in native e2e. The root feature map remains consumer-owned; do not register features or copy the registry inventory into the package. |
| README family keys, hashtable examples, comment/URL handling and canonical headers (`574f7d7`, `a7edc52`) | Already represented by per-module full-path reference discovery, dictionary example handling, the Bicep comment lexer and canonical metadata headers. Preserve independent Bicep source/JSON metadata and array-item example rules. |
| Rename-aware generation, deprecated-module filtering, RPC/parallel job fixes (`574f7d7`) | Registry batch-generation implementation, not the package's explicit module-scoped commands. Native compiler subprocesses already preserve diagnostics and checked exit codes; no RPC/job-draining shim is needed. |
| Gallery registration repair (`a7edc52`) | Package resolver uses checksum-pinned Gallery downloads and does not depend on registering PSGallery. Do not copy system/profile/PATH mutations or floating installers. |
| Image Builder/VHD/replication-region helpers, HCI assets, FinOps input, child publish allowlist | Consumer test assets/caller configuration, not package-owned implementations. Native e2e stages consumer sources and preserves authored scripts; updates remain in the pinned registry source rather than duplicated here. |
| Module releases, owner metadata, generated issue dropdown | No workflow/tooling behavior to adopt. No telemetry or shared metadata schema delta in this comparison. |

## Validation

- Focused unit run: 148 passed, none failed or skipped.
- Focused native component run: 108 passed, none failed or skipped.
- These include buffered metadata failures, narrow retry classifications,
  Graph/preflight proof, cleanup-state compatibility, same-region/mixed
  retry budgets, deployment-script protection, malformed native responses,
  and accepted-delete recovery without resubmission or repeated DELETE.
- The pin-refresh script verified all six Bicep 0.48.1 binary hashes.
- Final `.\build.ps1 pre-commit` passed: layout, lint, 3,285 unit passes
  (nine existing skips) and 1,472 component passes (one existing skip).
  The skips cover platform-specific paths/casing/native tar and the
  unreleased source-build gallery-note check. No assertion was removed.
- Additional raw-error-array compatibility and native recovery run: 112 units
  and 19 components passed.
- Final typed-HTTP-evidence regression run: 139 units passed. Native response
  status must be an integer or HTTP enum, not Boolean/string/array values
  that PowerShell might coerce into success or absence.
- Focused config-based documentation run: 19 units and 39 components passed,
  including literal JSON strings, native config comments, read-only caller
  files, shared provenance staging, strict explicit overrides and cleanup
  after compiler/launch failures.
- The initial real Bicep 0.48.1 run exposed removal of `--template-file` and an
  outdated scaffold pin assertion. After config-based rendering, all 19 Bicep
  native/static integration cases passed, including installed-package acceptance,
  all eight packaged PSRule baselines, the static-principal positive/removal-negative
  control, scoped README examples and native scaffold/telemetry compilation.
- Real Terraform provider-registration safeguards passed both AzureRM 3.117.1
  and 4.81.0 cases with AzAPI 2.13.0. These run local initialization, provider
  schemas and validation with Azure authentication disabled; they do not
  execute plans, deployments or registrations.
- Changed/new source files passed LF/UTF-8-without-BOM and `git diff --check`.
- No local Azure execution has occurred.

## Publication and hosted qualification

- Implementation commit: `3b4f6497bd0078b1b22bebb53ecf9d4f3f3a313d`.
- Review: [#235](https://github.com/Azure/azure-verified-modules-tools/pull/235).
- The [first hosted run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37590520300)
  passed lint, workflow tests, Linux/macOS coverage and components, all three
  Bicep integration jobs and all six approved Terraform integration jobs.
  The independent CodeQL analysis and CLA check also passed.
- Windows passed all 3,285 unit cases and its 70% coverage floor (73.77%),
  then reached the 25-minute job ceiling during component execution. The three
  completed component shards contained no failures; the fourth was canceled.
  This is incomplete qualification, not a passing Windows result.
- The [same job on the tools baseline](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37539203280/job/112527757202)
  already took 24 minutes 22 seconds: coverage took 8 minutes 46 seconds and
  components 14 minutes 58 seconds. The added regression cases exhausted that
  narrow margin. Raise only the Windows job ceiling to 30 minutes and update
  its workflow contract assertion; retain every test, per-test timeout, the
  70% coverage floor, all matrix entries and Linux/macOS ceilings.
- The corrected workflow passed all seven focused CI contract cases and a
  fresh `.\build.ps1 pre-commit`: layout, lint, 3,285 unit passes (nine existing
  skips) and 1,472 component passes (one existing skip). Hosted qualification
  of the corrected workflow remains pending.

## Boundaries and dependencies

The user explicitly approved publication and the six existing Azure-authenticated
Terraform CI jobs in the `avm` GitHub environment on 2026-10-07. That approval
does not cover local Azure canaries, additional deployments, provider
registrations, access changes, registry writes, merge or release. Existing
Terraform canary evidence applies only to unchanged runtime surfaces.
Package-owned native validation/defaults and strict explicit overrides remain
the contract. Registry caller cutover and any team runbook update require
separate approval.
