# Location-driven Terraform telemetry

**Status**: complete
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
- [x] Open the six module location-input reviews and the management-plane
      compatibility review, reusing relevant existing branches or reviews.
- [x] Run focused real-tool integration and the local pre-commit gate.
- [x] Commit and push the slice; verify the resulting checks.

## Validation

Real-mapotf and Terraform integration passed all 20 telemetry tests, including
required location creation, direct and nested Azure-resource children,
per-item location preservation, utility exemption, and local-state migration
with telemetry disabled. All 31 provider-requirement and 44 example cases
passed after regenerating both mock modules and their READMEs. Repeated
transforms and drift checks stayed clean.
`./build.ps1 pre-commit` passed with 1,837 unit tests, 9 platform skips,
803 component tests, and no errors. The updated
[published Terraform specification](https://github.com/Azure/Azure-Verified-Modules/pull/2980)
passed all seven checks.
The latest implementation commit passed a manually dispatched
[Authoring CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36162678139)
on all three operating systems and all six fixture integration legs; no
production deployment ran. GitHub did not schedule its usual pull-request
workflow for that push, so the manual run covered the same commit.
After merging the newer `main`, the combined metadata schema retained the
fixed seven-hex primary Terraform prefix while accepting descriptive
historical alternatives. Five focused metadata cases and the full
`./build.ps1 pre-commit` gate passed: 1,857 unit tests, 9 platform skips,
828 component tests, and no errors. The new
[automatic CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36165661226)
passed on the conflict-free merge commit, including all six integration legs
and all 19 review checks. Its first Windows AzAPI-fixture attempt could not
download a pinned tool because the asset endpoint returned HTTP 500; rerunning
that leg passed without a code change.

The related draft reviews are
[application group](https://github.com/Azure/terraform-azurerm-avm-res-desktopvirtualization-applicationgroup/pull/182),
[host pool](https://github.com/Azure/terraform-azurerm-avm-res-desktopvirtualization-hostpool/pull/161),
[scaling plan](https://github.com/Azure/terraform-azurerm-avm-res-desktopvirtualization-scalingplan/pull/174),
[workspace](https://github.com/Azure/terraform-azurerm-avm-res-desktopvirtualization-workspace/pull/183),
[Windows agent](https://github.com/Azure/terraform-azurerm-avm-ptn-azuremonitorwindowsagent/pull/150),
[AVD insights](https://github.com/Azure/terraform-azurerm-avm-ptn-avd-lza-insights/pull/176),
and [AVD management plane](https://github.com/Azure/terraform-azurerm-avm-ptn-avd-lza-managementplane/pull/191).
Non-deploying validation passed in the six single-input modules. The
management-plane tests await child releases compatible with the renamed
input, while its independent per-resource location mappings passed review.

## Blockers or dependencies

No production or live Azure deployment is authorized. Module callers may
need to supply a location after this change. The management-plane consumer
review depends on the renamed child inputs being released before it can
switch its module sources without compatibility aliases or version-floor
updates.
The [implementation review](https://github.com/Azure/azure-verified-modules-tools/pull/192)
includes the newer `main` without a conflict and has green checks. The
management-plane caller still needs compatible child-module releases before
its own module tests can pass.
