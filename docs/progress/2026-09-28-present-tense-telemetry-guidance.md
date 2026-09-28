# Present-tense telemetry guidance

**Status**: complete
**Started**: 2026-09-28
**Updated**: 2026-09-28
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

State only the current Terraform telemetry contract in reader-facing
documentation: module roots require `location` except utilities without
Azure resources; Azure-deploying children require it too. Do not describe
inputs or fallbacks that were only considered in earlier drafts.

Align the published specification with current `main`, the current Bicep
identifier format, and independent resource-specific location overrides.

## Checklist

- [x] Update current tooling documentation to describe required `location`
      without discussing unshipped inputs.
- [x] Refresh the existing published specification draft and its review
      description; verify documentation checks.
- [x] Commit and push this documentation slice on the active feature branch.

## Validation

The published SFR4 states that every Terraform root **MUST** declare
`location` except a utility with no Azure resources; Azure-deploying local
children **MUST** declare it as well. The public guidance tells consumers
to choose a valid region and describes independent resource-specific
overrides. Current tooling documentation and the draft descriptions no
longer discuss unshipped location inputs or fallback designs.
The [published specification draft](https://github.com/Azure/Azure-Verified-Modules/pull/2980)
includes current `main`, has no merge conflict, and passed all seven checks,
including the [Hugo build](https://github.com/Azure/Azure-Verified-Modules/actions/runs/36439178853).

## Blockers or dependencies

No production or live Azure work is required.
