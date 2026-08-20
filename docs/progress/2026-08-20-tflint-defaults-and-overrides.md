# Align TFLint defaults and overrides

**Status**: complete
**Started**: 2026-08-20
**Updated**: 2026-08-20
**Branch**: `jaredfholgate-align-tflint-tooling`

## Outcome

Align the packaged AVM TFLint configurations with the ruleset's default-enabled
policy, preserve intentional scope-specific exemptions, complete the MAPOTF
replacement transforms, and add safe per-scope customer TFLint overrides.
The slice also enforces AVM's one-layer module and example scope convention.

## Checklist

- [x] Reconcile packaged TFLint configurations with the coordinated ruleset
      changes and remove default-enabled AVM rule declarations.
- [x] Add deterministic MAPOTF transforms for Terraform version and provider
      declaration ordering, with regression coverage.
- [x] Support all-scope and safe per-example/per-submodule TFLint overrides with
      documented precedence and regression coverage.
- [x] Update direct user documentation for TFLint defaults and overrides.
- [x] Reject nested Terraform module and example roots through the built-in
      convention framework while allowing nested non-Terraform assets.
- [x] Publish the branch and open
      [pull request #78](https://github.com/Azure/azure-verified-modules-tools/pull/78).
- [x] Verify released v0.20.0 ruleset and v0.1.10 MAPOTF artifacts, then run
      real TFLint and MAPOTF validation.

## Validation

- Official `v0.20.0` ruleset and `v0.1.10` MAPOTF release checksums matched
  their downloaded Windows AMD64 assets.
- Ruleset [`sign-checksums` run](https://github.com/Azure/tflint-ruleset-avm/actions/runs/32404585686)
  completed successfully, validating all 12 release archives and creating a
  GitHub Artifact Attestation for `checksums.txt`. The released plugin installed
  through `signature = "attestation"` in the real TFLint integration test.
- MAPOTF [`sign-checksums` run](https://github.com/Azure/mapotf/actions/runs/32404645307)
  completed successfully, verified and attached the
  `checksums.txt.sigstore.json` bundle.
- `./build.ps1 integration`: 21 passed, 3 fixture-applicability skips, 0 failed.
  It installed MAPOTF v0.1.10 and TFLint v0.64.0, proved provider-entry ordering,
  and completed released TFLint plugin attestation/config validation.
- `./build.ps1 pre-commit`: 991 unit tests passed, 8 skipped, and all 28
  component tests passed.
- The released-pin [CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/32410893017)
  passed all three build legs, all six real-binary integration legs, aggregate
  test-results publishing, and coverage upload.
- The full [CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/32379042260)
  passed: all three build legs, all six real-binary Terraform integration legs,
  the aggregate test-results job, and coverage upload completed successfully.

## Blockers or dependencies

None.

## Release provenance

- Ruleset [v0.20.0](https://github.com/Azure/tflint-ruleset-avm/releases/tag/v0.20.0)
  targets `f46b7350ab22e5852e0f53316e8724745e6701bd`. Its checksum-signing
  workflow created a GitHub Artifact Attestation for `checksums.txt`; the
  released plugin installed through TFLint's `signature = "attestation"` mode
  during the real integration test.
- MAPOTF [v0.1.10](https://github.com/Azure/mapotf/releases/tag/v0.1.10)
  targets `ca40b49d41b4d081921146da693da855ff029576`. Its checksum-signing
  workflow verified and attached the released `checksums.txt.sigstore.json`
  bundle.
