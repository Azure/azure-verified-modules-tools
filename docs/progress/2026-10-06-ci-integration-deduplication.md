# CI integration deduplication

**Status**: blocked
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

After native/package correctness qualification, measure and remove repeated
Bicep-only integration execution from the two Terraform fixture legs per OS.
Retain all three OSes, Terraform fixture coverage, native negative cases,
coverage instrumentation, isolated unit workers and serial fallback.

## Baseline

Hosted run `37372219408` at published `6e834e9`:
CI-test steps Linux/macOS/Windows 489/618/703 seconds; integration steps
295/351/442 seconds (Azure fixture) and 348/364/415 seconds (AzureRM fixture).
Prerequisite installation takes 3-10 seconds. Offline jobs passed; integration
failed before the locally qualified policy-prerequisite fix, so these durations
are diagnostic observations, not a successful before/after comparison.

The workflow executes every Bicep integration file in both Terraform fixture
legs. Those five files do not consume AVM_INTEGRATION_FIXTURE, Terraform,
Azure credentials, deployment commands or Defender setup.

## Checklist

- [x] Capture equivalent safe Bicep execution on both old fixture legs.
- [x] Partition integration files without changing default local behavior.
- [x] Run Bicep integration once per OS without Azure login/Defender steps.
- [x] Assert partition completeness and result-aggregation dependencies.
- [x] Measure the same cases afterward and reconcile serial/sharded units.
- [x] Full local gate and commit; document hosted evidence limitation.

## Equivalent-work measurements

The measurements below use the corrected `de61ab7` authoring implementation,
Pester 5.7.1, the same Windows host and warm pinned tools. Earlier measurements
before the final package-default corrections are excluded.

| Invocation | Passed cases | Elapsed seconds |
| --- | ---: | ---: |
| Old Azure fixture leg, five safe Bicep suite selectors | 18 | 307.87 |
| Old AzureRM fixture leg, identical selectors | 18 | 267.22 |
| New `integration -IntegrationGroup Bicep`, no title filters | 18 | 300.14 |

NUnit case-name inventories match exactly across all three runs: the same
18 distinct cases passed, including the real policy and compliance negatives.
The old matrix repeats these cases twice per OS; the new matrix runs them
once per OS. Measured aggregate Windows Bicep execution is 575.10 -> 300.14
seconds, saving 274.96 seconds (47.8%) by removing redundant executions.
This is **not** a 47.8% reduction in whole-workflow elapsed time. Per-invocation
runtime did not improve, and the unchanged Windows coverage/component path
may still dominate hosted elapsed time. New hosted timings require publication.

The default `All` group preserves the complete 19-file integration inventory.
The Bicep and remaining shared/Terraform partitions have no overlap and their
union is exact. New Bicep-prefixed test files join the Bicep group automatically;
empty/invalid groups fail. Both Terraform fixtures still run on all three OSes.
The new Bicep job uses an isolated tool home, no Azure environment/login/token
permission or Defender step, and uploads results even after failure. The
report job waits for both integration groups. No cloud test was run locally.

## Other runtime findings and decisions

- Existing unit/component workers, process isolation, temporary directories,
  `AVM_HOME`, failed-container handling and the six-worker default are unchanged.
  Do not increase worker count without hosted CPU/memory evidence.
- On the final same test set, serial units took 482.00 seconds and the existing
  six-worker unit task took 106.35 seconds. Both produced exactly 3,028 passes
  and nine existing skips. All 3,037 case/result identities reconcile after
  normalizing unordered TestCases argument serialization; no cases disappeared.
  This confirms the prior sharding improvement, not a new performance claim.
- Historical NUnit weights already inform shard balancing. Coverage remains
  single-process and present on Linux/macOS/Windows; no coverage cases or floor
  were removed. Windows local coverage is 73.8% (9,527/12,910 commands across
  251 files), above the unchanged 70% floor, in 5m09.7s.
- Hosted prerequisite installation is only 3-10 seconds. The integration
  "cache" step creates per-job tool/provider directories rather than restoring
  a persistent Actions cache. No unqualified cross-job provider or tool cache
  was added. Separating Bicep removes its repeated compiler/policy setup from
  Terraform legs without weakening checksum/version resolution.
- Splitting the coverage/component matrix further would alter required-check
  topology and needs hosted measurement. It is not justified by local timing
  alone and was not implemented.

## Qualification

The final ordinary Pester 5 full gate passed layout/lint, all units and
1,563 components (one existing skip), in 9m40.5s. Separate final coverage passed.
Pester 6.2.0 passed 23 focused CI-selection/sharding/workflow cases. Pester 5/6
package-default and native-suite qualification is recorded in the correctness
slices. Evidence logs and NUnit before/after/serial/sharded inventories remain
in this session's files directory.

## Blocker

Current-head hosted execution remains unavailable under the publication hold.
No workflow is manually dispatched and no authentication change is authorized.
