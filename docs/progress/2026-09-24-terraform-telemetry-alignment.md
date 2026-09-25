# Terraform telemetry alignment

**Status**: in-progress
**Started**: 2026-09-24
**Updated**: 2026-09-25
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Replace mapotf-generated `modtm` telemetry with an empty AzAPI ARM deployment
whose identifier and canonical type come from module-owned `metadata.json`.
Preserve the existing telemetry opt-out and migrate legacy Terraform state
without destroying the retired resource.

The upstream proposal requires an `avm_module_tier` tag, but the rolled-out v1
metadata contract intentionally has no tier field. The requester chose to keep
that metadata contract and use four reporting tags instead. The requester also
chose subscription scope for all deployments, including child modules with
telemetry prefixes. An optional `telemetry_location` belongs on every
instrumented module: with `var.location` it defaults to `null` and falls back
to that input; without it the default is `westus2`. Standard `modtm` mocks,
test-module provider declarations, and resource references should be migrated
automatically; custom mocks must fail explicitly.

## Checklist

- [x] Finalize deployment scope and source-shape details against the proposal.
- [x] Update mapotf rules for metadata-derived telemetry and `modtm` migration.
- [x] Update related fixtures, tests, and documentation for the four-tag contract.
- [x] Run focused validation and `./build.ps1 pre-commit`.
- [x] Commit and push the slice on the feature branch.

## Validation

`./build.ps1 pre-commit` passed: 1,821 unit tests passed (9 platform skips)
and 799 component tests passed; 50 existing warning-level diagnostics and no
errors. Focused real-mapotf integration tests cover a prefixed root and child,
telemetry-free helpers, location defaults and overrides, examples, and
standard test migration. Mocked Terraform applies verify the exact four-tag
shape, all four source-type classifications without raw source paths,
opt-out, and a maximum-length 64-character deployment name. Both fixture
unit suites run with mocked providers. A local state upgrade proves the old
provider must be installed once, then both legacy addresses are forgotten
without a destroy. No live Azure resources were changed.

## Follow-up — TFLint compatibility

The first CI run passed unit, component, and workflow checks but failed all
six Terraform integration legs. The pinned AVM TFLint plugin still requires
`modtm` in the root config and enforces `tags = var.tags` on every taggable
AzAPI resource, including the generated four-tag telemetry deployment.

- [x] Disable the obsolete root `modtm` rule without disabling other AzAPI
      tag checks.
- [x] Add `response_export_values = []` to the generated telemetry resource
      and a single-resource inline tag-rule exemption after mapotf writes it.
- [x] Cover ordinary AzAPI tag enforcement, generated telemetry lint, and
      the stubbed component chain with focused tests.
- [x] Pass the final local gate and focused TFLint attestation.
- [ ] Commit and push the fix; confirm CI integration across all three
      operating systems.

The repaired gate passed with 1,824 unit tests (9 platform skips) and 799
component tests, no errors. The real pinned TFLint attestation confirmed
that generated telemetry passes while two ordinary AzAPI resources with
nonstandard tags still fail. No live Azure resources were changed locally.

## Blockers or dependencies

The published Terraform module specification has a draft update in
[Azure/Azure-Verified-Modules#2980](https://github.com/Azure/Azure-Verified-Modules/pull/2980).
The customer-facing
`Azure-Verified-Modules-Docs` guidance, Grafana tag visibility/correlation,
OpenTofu compatibility, and subscription-scope permission-failure canary are
release gates. No production or canary deployment has run.
