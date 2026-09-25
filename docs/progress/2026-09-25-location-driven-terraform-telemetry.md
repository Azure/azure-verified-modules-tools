# Location-driven Terraform telemetry

**Status**: in-progress
**Started**: 2026-09-25
**Updated**: 2026-09-25
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Remove the separate `telemetry_location` input. Require `var.location` for
Terraform module roots and for local submodules that deploy Azure resources;
create the input when missing, forward the root location into those children,
and use it for subscription-scoped deployment telemetry. Utility modules that
deploy no Azure resources remain exempt.

Publish the matching Terraform specification change and coordinate separate
module pull requests to rename the six single-purpose resource location
inputs to `location`. Also update the AVD management-plane caller so its
existing four distinct location choices reach those renamed child inputs.

## Checklist

- [x] Update MaPoTF location generation and forwarding for roots, Azure
      resource children, and examples; remove legacy telemetry-only input.
- [x] Update fixture modules, regression tests, and tooling documentation.
- [x] Update the existing published Terraform specification draft.
- [ ] Open the six module location-input reviews and the management-plane
      compatibility review, reusing relevant existing branches or reviews.
- [x] Run focused real-tool integration and the local pre-commit gate.
- [ ] Commit and push the slice; verify the resulting checks.

## Validation

Real-mapotf and Terraform integration passed all 20 telemetry tests, including
required location creation, direct and nested Azure-resource children,
per-item location preservation, utility exemption, and local-state migration
with telemetry disabled. All 31 provider-requirement cases passed. Of the
44 example cases, 42 passed before fixture regeneration; the two deliberate
fixture-drift failures passed after transforming and regenerating both mock
modules and their READMEs. Repeated transforms and drift checks stayed clean.
`./build.ps1 pre-commit` passed with 1,837 unit tests, 9 platform skips,
803 component tests, and no errors. The updated
[published Terraform specification](https://github.com/Azure/Azure-Verified-Modules/pull/2980)
passed all seven checks.

## Blockers or dependencies

No production or live Azure deployment is authorized. Module callers may
need to supply a location after this change. The management-plane consumer
review depends on the renamed child inputs being released before it can
switch its module sources without compatibility aliases.
