# Native Bicep distribution qualification

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Qualified an unsigned local distribution containing the native Bicep runner
from `a71b8788542cc912b674ffe80fd8c288479a29da` plus the explicit version-check
forwarding correction in `Invoke-AvmTestE2e`. The report records that
working-tree source boundary and every payload hash; this is not an
unchanged-commit artifact. Extracted bytes, command origins, native lifecycle
contracts and unmodified registry cases passed. This is not release or live
Azure qualification.

## Checklist

- [x] Refresh package selectors for the native runner and reject unmatched
      selectors instead of silently losing coverage.
- [x] Ensure fresh-process native Pester fixtures use the loaded module,
      including an extracted package, rather than importing checkout source.
- [x] Build through `build.ps1`, byte-verify the archive and import it by name
      in an isolated module search path.
- [x] Run packaged contracts and frozen-registry scenarios offline, with
      simulated Azure and real compiler/authored Pester execution.
- [x] Preserve an explicit version-check override through nested e2e context
      discovery; do not weaken normal version enforcement.
- [x] Add lifecycle/input tests for the hosted unit-coverage shortfall and
      pass local coverage without changing the floor or exclusions.
- [x] Run the ordinary development gate and prepare the owned commit.

## Validation

The first extracted-package probe exposed a genuine public-boundary bug:
`Invoke-AvmTestE2e -SkipModuleVersionCheck` did not pass that explicit choice
to its nested context lookup. Source tests inherited the build's test-only
override and therefore did not expose it. The existing switch now reaches
context discovery, with controls for both enabled and disabled values.
The standalone package probe did not use the test-only bypass.

The updated package-contract selector covers native lifecycle, recovery,
inputs and output compatibility. Every selector must match an executed test.
Fresh-process fixtures resolve their manifest from the loaded module so
package qualification cannot silently fall back to checkout source.

The corrected unsigned `Avm.Authoring` 0.0.0 archive has SHA-256
`D80D3D4D0E9E45AB99B562F62AB1921732D1A5F98D7499A0C39D0A6CDA012187`.
All 348 extracted payload files matched staging byte for byte. A fresh
PowerShell process imported the module by name from an isolated search path
and resolved all 30 exported commands plus 26 native helpers inside the
extracted artifact. The final source files still matched the recorded
payload hashes after the development gate.

Packaged contracts passed 158 unit and 143 component tests without skips.
Five separately identified scaffold regressions used the real pinned Bicep
0.47.16 compiler. Six frozen-registry scenarios also used that compiler and
simulated Azure: subscription-to-group, management-group role definition,
management-group `init`/`idem`, tenant service group, and the unchanged
PostgreSQL assertion suite with correct and deliberately wrong responses.
The negative control failed its authored assertion while cleanup completed.
All 5,611 registry snapshot files remained byte-identical. No registry child
case or `post.ps1` execution is claimed by these real-source scenarios.

The prior hosted Windows and macOS coverage result was 69.57%, below the
unchanged 70% floor, despite passing unit tests. Added 47 case/completion
controls, eight CI-environment controls and two version-policy controls.
The focused batch passed 77 tests. The final ordinary
`build.ps1 coverage,pre-commit` passed layout and lint, 2,807 unit tests and
1,257 component tests, with nine unit skips and one component skip. Local
coverage is 73.18%: 8,828 of 12,064 commands across 229 files. Hosted results
for the new commit must still be checked; this local result does not replace
them.

The archive, JSON reports, compiler/scenario evidence and final gate log
are retained under the session's `bicep-workflow-parity` evidence directory.
The successful artifact is `native-package-a71b878-02`; the first artifact
records the pre-correction failure and is not the qualified package.

## Blockers or dependencies

No downloads, dependency installation, live Azure execution, release or
registry workflow cutover is authorized. Use the existing compiler/cache
and installed development modules. Signed-release qualification and
explicitly approved live resource creation/deletion remain separate.
The overall [workflow-parity slice](2026-10-02-bicep-workflow-parity.md)
continues to track those gates and hosted verification.
