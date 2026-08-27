# Demote the fleet-blocking AzAPI lint rules to notices

**Status**: complete
**Started**: 2026-08-26
**Updated**: 2026-08-26
**Branch**: `defer-azapi-lint-enforcement`

## Outcome

Restore a green `avm pr-check` lint step across the AVM Terraform fleet without hiding the work it was flagging, and without reverting the legitimate intent of [pull request #78](https://github.com/Azure/azure-verified-modules-tools/pull/78).

The activation happened in two steps, not one. [Pull request #70](https://github.com/Azure/azure-verified-modules-tools/pull/70) adopted ruleset 0.19.1 and added `resource_types`, `retry`, `timeouts` and `ignore_body_changes` to the allow-list as `enabled = true`, shipping in 0.9.4. Two days later [pull request #78](https://github.com/Azure/azure-verified-modules-tools/pull/78) removed `config { disabled_by_default = true }` from all three packaged configurations, flipping TFLint from allow-list to deny-list semantics and activating every remaining default-enabled AVM rule at once — `provider_azurerm_disallowed`, `azapi_response_export_values`, `azapi_data_response_export_values` and `no_entire_resource_output_tffr2` — shipping in 0.10.0. Reverting #78 alone would therefore not restore the prior state, because the four variable rules were enabled deliberately by #70.

Between them, the two families blocked lint in 180 of 188 non-archived `Azure/terraform-azurerm-avm-*` repositories: `provider_azurerm_disallowed` (family 1) and the TFFR6/7/8 interface rules `resource_types`, `retry`, `timeouts`, `ignore_body_changes`, plus `azapi_response_export_values` (family 2). Cause analysis and fleet impact data are recorded in [issue #80](https://github.com/Azure/azure-verified-modules-tools/issues/80).

The first implementation disabled the six rules in the packaged configurations. That unblocked the fleet but made the outstanding work invisible: nobody could see what their module owed, and the eight already-clean repositories could regress silently. On review feedback the approach changed to demotion. The rules stay enabled, every finding is still reported with file and line, and the lint engine rewrites their severity from `error` to `notice` so they no longer fail the gate.

TFLint cannot do this itself. Severity is an immutable property of each rule and there is no `severity` attribute for a config `rule` block; upstream declined the request in [terraform-linters/tflint#715](https://github.com/terraform-linters/tflint/issues/715). The only config-side levers are `enabled`, inline `tflint-ignore` annotations, and `--minimum-failure-severity`, which is a single global threshold rather than a per-rule control. The demotion therefore lives in `Invoke-AvmTerraformLint`, which already parses tflint's `--format=json` output and already computes pass/fail from the parsed severities rather than from tflint's exit code.

## Design for removal

These deferrals are temporary, so restoring enforcement is deliberately cheap:

- The rule names live in exactly one place, `Get-AvmDeferredAzapiRule`, split into the two families so either can return independently.
- Deleting a name restores enforcement for that rule. Deleting an array restores a whole family. An empty list makes the demotion a no-op, so the mechanism can be left in place or removed wholesale.
- Every touchpoint is tagged `AVM-DEFERRED-AZAPI`, so `git grep AVM-DEFERRED-AZAPI` finds the list, the predicate, the parse-time demotion and the warning emission.
- `tests/Pester/Unit/Private/Engines/DeferredAzapiRules.Tests.ps1` pins the list exactly, so any change is a reviewed one rather than silent drift.

## Checklist

- [x] Add `Get-AvmDeferredAzapiRule` and `Test-AvmDeferredAzapiRule` to `src/Avm.Authoring/Engines/Terraform/Invoke-AvmTerraformLint.ps1`.
- [x] Demote matching issues from `error` to `notice` at parse time in `Invoke-AvmTflintScope`, so `Status`, the emitted warnings and the returned `Issues` all agree on one severity.
- [x] Emit the demoted findings as non-failing warnings with source locations, reusing the existing `deprecated_*_interface` emission path and its `Register-AvmPresentedIssue` de-duplication.
- [x] Leave all three packaged TFLint configurations unchanged, so the rules keep running.
- [x] Document the behaviour and the removal procedure in the `Invoke-AvmTerraformLint` help block and `src/Avm.Authoring/README.md`.
- [x] Add `tests/Pester/Unit/Private/Engines/DeferredAzapiRules.Tests.ps1`.
- [x] Cut the `## [0.10.2] - 2026-08-26` section in `CHANGELOG.md`.
- [x] Add `azapi_data_response_export_values` to the deferred TFFR6/7/8 family and cut `## [0.10.3] - 2026-08-26`. See the follow-up section below.

## Validation

- `tests/Pester/Unit/Private/Engines/DeferredAzapiRules.Tests.ps1`: 7 passed. The behavioural case feeds a synthetic tflint JSON payload in which `provider_azurerm_disallowed` and `terraform_unused_declarations` are both reported as `error`, and asserts the first comes back as `notice` while the second stays `error`. That proves the finding is demoted rather than dropped, and that unrelated rules still fail the gate.
- `tests/Pester/Unit/Changelog/ChangelogContract.Tests.ps1`: 5 passed. The ADO release pipeline parses `CHANGELOG.md` to build the manifest `ReleaseNotes` and the GitHub release body, so a malformed heading would surface as empty release notes only after the tag was cut.
- `./build.ps1 pre-commit`: layout, lint and unit legs green.
- Because the rules stay enabled, `tests/Pester/Integration/TflintAttestation.Integration.Tests.ps1` needs no change. Its probe asserts that a bare `azapi_resource` trips `ignore_body_changes`, and it invokes tflint directly rather than through `Invoke-AvmTerraformLint`, so engine-side demotion does not affect it. The earlier disable-based implementation had required `--enable-rule` flags there; that workaround is gone.
- The canonical fixture `terraform-azure-avm-res-mock` declares all four interface variables and contains no `azurerm_*` blocks, so it trips none of the six rules. `CanonicalResult.Status | Should -Be 'pass'` and `CanonicalWarnings | Should -BeNullOrEmpty` therefore remain valid.
- Integration tests cannot run on the authoring host: `avm.pins.jsonc` declares `unsupportedPlatforms: ["windows-arm64"]` for tflint, so the Component leg throws `AvmToolException` locally. Integration coverage was verified in CI.

## Follow-up: `azapi_data_response_export_values` (0.10.3)

Two module repositories were re-checked against the released 0.10.2 to confirm the demotion reached CI. It had: in [`terraform-azurerm-avm-res-network-connection`](https://github.com/Azure/terraform-azurerm-avm-res-network-connection/actions/runs/32796194846/job/98363427447) and [`terraform-azurerm-avm-res-communication-emailservice`](https://github.com/Azure/terraform-azurerm-avm-res-communication-emailservice/actions/runs/32998561580/job/98363262684) all six deferred rules were reported as non-failing warnings and excluded from the failure summary, exactly as designed.

Both still failed, on other rules. `network-connection` failed only on `terraform_module_version`, which was `enabled = true` with `exact = true` well before #78 and is a genuine repository-side fix. `emailservice` failed on three ERROR-severity rules, one of which is a gap in the deferral: `azapi_data_response_export_values`.

That rule is the `data`-block twin of the deferred `azapi_response_export_values` — the ruleset registers the pair separately, covering `data` blocks of type `azapi_resource`, `azapi_resource_action`, and `azapi_resource_list`. Both are ERROR severity, both default-enabled, and neither appeared in the pre-#78 allow-list, so both became active for the first time in 0.10.0. Deferring one and not the other was an oversight in the original list rather than a deliberate distinction, so the data variant was added to the same family.

Measured exposure: at least 26 non-archived `Azure/terraform-azurerm-avm-*` repositories declare such a data block. That is a lower bound — GitHub code search caps at 100 results per query, and `emailservice` itself did not appear in the result set despite failing on the rule.

The other two `emailservice` failures were left enforced, deliberately. `no_entire_resource_output_tffr2` was also absent from the pre-#78 allow-list and is worth a fleet measurement before any decision. `azapi_resource_tag` is different in kind: the pre-#78 allow-list carried its former name `azurerm_resource_tag` with `enabled = true`, and #78 renamed it, so enforcement there is continuous rather than newly introduced.

## Blockers or dependencies

An `Avm.Authoring` release is required for this change to reach module-repo CI, because module repositories install the published module from the PowerShell Gallery on every run rather than consuming `main`. That install is unpinned, so the fleet picks the fix up automatically on the next CI run once it publishes - the same mechanism that spread the regression within eighteen minutes of #78 merging. Until then, affected repositories can unblock with the repository-root `avm.tflint.override.hcl` support added in #78.

Re-enablement is tracked in issue #80 and is deliberately split: family 2 (TFFR6/7/8) is mechanical and should return first once the variable burn-down lands; family 1 waits on the per-module AzureRM-to-AzAPI migration epics.
