# Mapotf module subdirectories

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-fix-mapotf-errors`

## Outcome

Fix the module-source inspection failures in the
[hub-and-spoke](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34330602969/job/102398143517)
and [virtual-WAN](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34330602969/job/102398143462)
repository-sync jobs. Mapotf 0.1.11 downloads the accelerator repository but
inspects its root instead of the requested `config-templating` subdirectory.

The upstream fix resolves the synthetic module `x` through Terraform's module
manifest before inspecting its variables. AVM now pins the published mapotf
0.1.12 release and all six official platform checksums, with deterministic
regression coverage for the module-ordering rules.

Upstream: [Azure/mapotf#127](https://github.com/Azure/mapotf/pull/127).
Consumer: [#108](https://github.com/Azure/azure-verified-modules-tools/pull/108).

## Checklist

- [x] Identify the shared failure and confirm the upstream hardcoded directory.
- [x] Implement and submit the upstream mapotf fix.
- [x] Add deterministic AVM coverage for Git module subdirectory ordering.
- [x] Confirm the user's published mapotf 0.1.12 release.
- [x] Refresh verified tool pins from the published release.
- [x] Run focused integration coverage and the pre-commit gate.
- [x] Commit, push, and prepare the existing AVM update for review.

## Validation

- Focused `.\build.ps1 integration` against pinned mapotf 0.1.11 reproduced
  both failure modes: a subdirectory without root Terraform files raises the
  reported download error, while a root with conflicting variable defaults
  silently produces the wrong input order. The Git repository-root control
  passes. Result: one passed, two failed as expected before the upstream fix.
- The fixtures use local Git repositories, commit-pinned `file://` sources,
  vendored module-ordering rules, and no providers or Azure resources.
- The same three integration cases pass against the upstream
  `0.1.12-dev` Windows candidate, including a second identical transform.
  The test file accepts the candidate through Pester container data
  (`MapotfPath`); normal runs still use the verified pinned binary.
- Repeated the three-case integration run against the final local binary from
  upstream commit `16504384939db91d28c6afdd0dfe88b496b67fd5`: all passed.
  The binary SHA256 is
  `85b99a14703924fd40af1bebcf3e425ddc952bdc62a20e182d3477bfbcab6d60`;
  it is an unsigned development artifact, not a release asset.
- Initial `.\build.ps1 pre-commit`: passed with 1,043 unit cases passed, eight skipped,
  and 29 component cases passed. PSScriptAnalyzer reported 162 non-blocking
  warnings and recovered after its existing transient-crash retries.
- `.\scripts\Update-AvmPins.ps1 -Mapotf 0.1.12` refreshed all six SHA256
  values from the official release checksum manifest and validated the pin file.
- Focused `.\build.ps1 integration` using the released, checksum-verified
  0.1.12 binary: all 20 cases passed with no skips. This includes the three
  Git module-source cases and 17 existing provider-requirement cases.
- Final `.\build.ps1 pre-commit` with the new pin: 1,043 unit cases passed,
  eight skipped, and 29 component cases passed. Layout and lint passed;
  PSScriptAnalyzer reported 189 non-blocking warnings after its existing
  transient-crash retries.

## Blockers or dependencies

The user published
[mapotf 0.1.12](https://github.com/Azure/mapotf/releases/tag/v0.1.12)
with all six platform archives, `checksums.txt`, and its Sigstore bundle.
The upstream release dependency and pin adoption are complete.
The user must merge the AVM update and publish Avm.Authoring before repository
sync, which installs from PowerShell Gallery, consumes the fix.
The user owns merging and publishing releases; the agent must not perform
either operation. Rerunning repository sync separately requires explicit
approval.
