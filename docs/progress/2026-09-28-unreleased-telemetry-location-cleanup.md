# Unreleased telemetry location cleanup

**Status**: complete
**Started**: 2026-09-28
**Updated**: 2026-09-28
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Keep the required `var.location` telemetry contract, but remove MaPoTF rules
that delete `telemetry_location` declarations or call arguments. The
intermediate `telemetry_location` design was never released to module
repositories, so no migration for that input is necessary.

## Checklist

- [x] Remove unused `telemetry_location` migration rules from the root,
      module-call, and example profiles.
- [x] Replace tests for hypothetical `telemetry_location` migration with
      coverage of required `location` forwarding and generated output.
- [x] Correct current documentation and the existing draft review description
      to distinguish the unshipped proposal from a released input.
- [x] Run focused real-mapotf checks and the local pre-commit gate.
- [x] Commit and push this slice to the active branch; verify its checks.

## Validation

Focused real-mapotf integration passed for existing and newly created
example `location` inputs, generated example documentation, and instrumented
child forwarding (4 tests). The profile code no longer reads or removes
`telemetry_location`; only tests that assert it is not generated mention the
unshipped input. No live Azure resources were changed.
The complete real-mapotf telemetry and example integration selection passed
all 64 cases, including provider-free legacy state migration and idempotent
location forwarding.
`./build.ps1 pre-commit` passed with 1,857 unit tests, 9 platform skips,
828 component tests, and no errors. The draft
[implementation review](https://github.com/Azure/azure-verified-modules-tools/pull/192)
now says the unshipped input has no migration or deletion path.
The new head passed
[Authoring CI](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36399959188)
on Windows, macOS, and Ubuntu, including all six fixture integration jobs;
[repository configuration tests](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36399959191)
also passed. All 19 review checks are green.

## Blockers or dependencies

No live Azure deployment or production run is authorized.
