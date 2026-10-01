# E2E retry for ineligible regions

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Completed**: 2026-10-01
**Branch**: `jaredfholgate-e2e-retry-location-ineligible`

## Outcome

`avm test e2e` now destroys and retries an example when Azure rejects its
randomly selected region with `RequestDisallowedByAzure` and the
`aka.ms/locationineligible` explanation ("The selected region is currently not
accepting new customers"). This failure stopped the
[network interface module's PR Check](https://github.com/Azure/terraform-azurerm-avm-res-network-networkinterface/actions/runs/36844305951)
on Avm.Authoring v0.19.0 after one `terraform apply`, without a
`terraform destroy (retry 1)`.

PR #175 added this error to the integration classifier,
`Test-AvmTerraformTestCompleted`, but not to `Test-AvmTerraformTransientError`,
which the e2e engine uses. Both now share
`Test-AvmTerraformLocationIneligibleError`, which requires the code and the
link together. Other `RequestDisallowedByAzure`, `RequestDisallowedByPolicy`,
and authorization denials still do not trigger a retry. The integration
classifier keeps rejecting every other HTTP 403 or `RequestDisallowedByAzure`
diagnostic, so its behaviour is unchanged.

## Checklist

- [x] Add the shared region-ineligible check to the e2e classifier.
- [x] Reuse the check in the integration classifier without changing its
  results.
- [x] Add classifier, engine, and stub-backed component coverage.
- [x] Update the Terraform migration guide, command help, and changelog.
- [x] Run the repository pre-commit gate.
- [x] Commit, push, and open the pull request.

## Validation

- `./build.ps1 pre-commit` passed after merging the latest `main`: layout,
  lint with no findings, 2,055 unit tests, and 936 component tests.
- The focused retry tests also passed under Pester 6.2.0, which CI installs:
  131 tests.
- The new classifier, engine, and component tests fail when the classifier fix
  is reverted.
- Comparing the previous and new `Test-AvmTerraformTestCompleted` across 6,144
  generated diagnostics found no differences.

## Blockers or dependencies

None. Module repositories receive the fix with the next Avm.Authoring release.
