# Ubuntu component runtime

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-fix-mapotf-errors`

## Outcome

Resolve the Ubuntu component failures after the main-branch merge in
[#108](https://github.com/Azure/azure-verified-modules-tools/pull/108).
[Run 34362487724](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34362487724)
passes all six real-binary integration jobs and its unit/coverage tier, but
child PowerShell processes start crashing during the component tier.

The crash reports a malformed `System.Collections.Specialized` assembly name
and exit code 134. Subsequent stub-resolution failures install real tools,
causing secondary component assertions to fail.

The signature matches
[PowerShell/PowerShell#26528](https://github.com/PowerShell/PowerShell/issues/26528)
and [dotnet/runtime#121977](https://github.com/dotnet/runtime/issues/121977):
concurrent processes can corrupt the shared `StartupProfileData-NonInteractive`
file. The original runner's damaged file is unavailable, so that specific
corruption event has not been proven or reproduced deterministically.

The user approved a CI-only workaround: set
`DOTNET_MultiCoreJitMinNumCpus=7fffffff` before PowerShell starts. The runtime's
CPU-count gate then disables startup-profile consumption and recording.
Ordinary JIT compilation, all test suites, and coverage thresholds remain intact.

## Checklist

- [x] Identify the first runtime crash and separate it from cascading failures.
- [x] Compare matching Linux runtime versions and identify the upstream defect.
- [x] Apply the approved CI-only workaround without weakening assertions.
- [x] Run the local pre-commit gate, including the workflow-environment guard.
- [x] Push the approved mitigation for full-matrix CI.

## Validation

- A checksum-verified portable PowerShell 7.6.5 runtime was used for Linux
  reproduction. Its component tier passed with Pester 5.7.1 (28 passed, one
  skipped), and 12 focused cases passed with the runner's Pester 6.1.0.
- The isolated full-CI attempt stopped at two Git-metadata assertions because
  its source archive was not a Git checkout; this was not the hosted failure.
- Controlled profile mutations did not reproduce the startup abort and are not
  evidence that the workaround resolves the specific corrupted runner profile.
- The runtime gate and workaround are source-backed; replacement hosted CI is
  the acceptance gate for this approved mitigation.
- `.\build.ps1 pre-commit` passed with the new workflow guard and all 29
  Windows component cases. The existing analyzer retry recovered from three
  transient crashes and reported 165 non-blocking warnings.
- Full-matrix results are tracked in
  [the existing review's checks](https://github.com/Azure/azure-verified-modules-tools/pull/108/checks).
  No tests or assertions are skipped by the workaround.

## Blockers or dependencies

The mitigation is committed as `f80f4be`. The initial workflow-scope push
restriction was resolved using the user's explicitly authorized stored
credentials, and the change is published to the review branch.

The user owns merging and publishing. No production execution is needed.
