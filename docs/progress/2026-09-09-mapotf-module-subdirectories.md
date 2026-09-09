# Mapotf module subdirectories

**Status**: blocked
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-fix-mapotf-errors`

## Outcome

Fix the module-source inspection failures in the
[hub-and-spoke](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34330602969/job/102398143517)
and [virtual-WAN](https://github.com/Azure/azure-verified-modules-tools/actions/runs/34330602969/job/102398143462)
repository-sync jobs. Mapotf 0.1.11 downloads the accelerator repository but
inspects its root instead of the requested `config-templating` subdirectory.

The upstream fix belongs in `Azure/mapotf`: resolve the synthetic module `x`
through Terraform's module manifest before inspecting its variables.
This slice covers AVM regression coverage and adoption of the patched release.

Upstream: [Azure/mapotf#127](https://github.com/Azure/mapotf/pull/127).
Consumer: [#108](https://github.com/Azure/azure-verified-modules-tools/pull/108).

## Checklist

- [x] Identify the shared failure and confirm the upstream hardcoded directory.
- [x] Implement and submit the upstream mapotf fix.
- [x] Add deterministic AVM coverage for Git module subdirectory ordering.
- [ ] Publish the upstream patch after approval and refresh verified tool pins.
- [ ] Run focused integration coverage and the pre-commit gate.
- [x] Commit, push, and open the AVM update as a dependency-blocked draft.

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
- `.\build.ps1 pre-commit`: passed with 1,043 unit cases passed, eight skipped,
  and 29 component cases passed. PSScriptAnalyzer reported 162 non-blocking
  warnings and recovered after its existing transient-crash retries.

## Blockers or dependencies

The latest published mapotf version is 0.1.11. The AVM pin must not change until
the fixed release and its official platform checksums are available.
The user owns merging and publishing releases; the agent must not perform
either operation. Await the user's mapotf 0.1.12 release before refreshing
the pin. Rerunning repository sync separately requires explicit approval.
The new integration regression intentionally remains red with the old pin;
the consumer change must stay draft until adoption of the upstream patch.
