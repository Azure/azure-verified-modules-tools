# Provider-free telemetry migration regression

**Status**: complete
**Started**: 2026-09-25
**Updated**: 2026-09-25
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Add a standalone Terraform test module whose canonical configuration has no
random provider. Migrate a staged legacy copy containing telemetry-only
`random_uuid` and `modtm` resources, and verify that the transform removes the
obsolete provider declarations without disturbing other providers or
destroying old state.

Stop reporting the generated telemetry deployment's exact TFLint ignore
directive as an author warning. Continue to warn for other inline ignores
and enforce the tag rule on ordinary AzAPI resources.

## Checklist

- [x] Add a provider-free module fixture and exercise the real telemetry
      migration and non-destructive state cleanup against it.
- [x] Suppress only the generated telemetry ignore warning; cover other
      inline ignores and ordinary resource-tag linting.
- [x] Run focused integration and the local pre-commit gate.
- [x] Commit and push to the existing feature branch and verify its checks.

## Validation

The new fixture declares AzAPI but no random provider or `var.location`.
The real-mapotf integration stages old `random_uuid` and `modtm` telemetry on
a copy, then checks that both obsolete provider declarations disappear,
the AzAPI declaration remains, generated deployment telemetry is tagless,
and repeated transforms are stable. Synthetic local state proves Terraform
forgets both old addresses without destroying resources; the first init
loads the former providers, while later init and provider inspection do not.
Telemetry is disabled during the local-state apply, so no Azure resources
are changed.

The focused inline-ignore unit tests passed all nine cases, including
root/child generated directives and author-written, altered, and misplaced
ignores. The real pinned TFLint integration passed: it no longer warns for
generated telemetry, still warns for a manual ignore and a disabled override,
and still flags ordinary AzAPI resources with nonstandard tags.
`./build.ps1 pre-commit` passed with 1,837 unit tests, 9 platform skips,
803 component tests, and no errors; 50 existing warning-level diagnostics
were emitted.
The implementation passed [Authoring: CI](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36150636440)
on Windows, macOS, and Ubuntu, including all six fixture integration jobs.
The Windows test job initially hit its 15-minute limit during the component
tier; rerunning that failed job completed in 8 minutes 42 seconds with no
code change. All 19 review checks are green.

## Blockers or dependencies

No live Azure or production deployment is authorized. The legacy-state test
uses local state and disables telemetry during apply; one initial Terraform
init with the former providers remains necessary before state can forget them.
