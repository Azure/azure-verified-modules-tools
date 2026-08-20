# Adopt TFLint ruleset AVM 0.21

**Status**: complete
**Started**: 2026-08-20
**Updated**: 2026-08-20
**Branch**: `jaredfholgate-adopt-tflint-0-21`

## Outcome

Adopt the released `Azure/tflint-ruleset-avm` `v0.21.0` and its
`azapi_replace_triggers_refs` omission semantics with verified release
provenance.

## Checklist

- [x] Update packaged TFLint configuration and the mirrored AVM plugin pin.
- [x] Remove empty `replace_triggers_refs` fixture declarations.
- [x] Document the optional, non-empty replacement-trigger contract.
- [x] Cover version generation, fixture omission, and real plugin attestation
      in structural, unit, component, and integration tests.
- [x] Run the local build and applicable integration validation.
- [x] Publish the branch and open
      [pull request #79](https://github.com/Azure/azure-verified-modules-tools/pull/79).
- [x] Verify the released plugin, complete local validation, and clear the PR
      blocker language.

## Validation

- `./build.ps1 pre-commit` passed after the packaged configuration, pin,
  fixture, unit, and component updates.
- Published commit `ad066bd05494aa19d22d2af3decab1a99e8b9ed5` on
  `jaredfholgate-adopt-tflint-0-21` and opened
  [pull request #79](https://github.com/Azure/azure-verified-modules-tools/pull/79).
- Refreshed the released plugin pin with
  `./scripts/Update-AvmPins.ps1 -TflintPlugin @{ avm = '0.21.0' }`.
- Verified release `v0.21.0` is final, targets
  `96d1d037cb1cc1455621703fc69dd42a539a54f0`, and publishes all platform
  archives plus `checksums.txt`.
- Downloaded `checksums.txt`, verified SHA-256
  `c2b5eefb6493900d76ead84f3cb33d9990efd287e25f69b69073dc5d28dcc439`,
  and verified its GitHub Artifact Attestation. The attestation identifies the
  release-triggered `sign-checksums` workflow at the release commit:
  [run 32425689033](https://github.com/Azure/tflint-ruleset-avm/actions/runs/32425689033).
- `./build.ps1 pre-commit`: passed.
- `./build.ps1 integration`: 21 passed, 3 fixture-applicability skips, 0 failed.
  The real TFLint test installed and ran the released `v0.21.0` AVM plugin via
  GitHub Artifact Attestation.
- The full [CI run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/32427241247)
  passed all build and real integration matrix legs, aggregate test-results
  publishing, and coverage upload.

## Dependencies

- The ruleset implementation merged through
  [tflint-ruleset-avm #156](https://github.com/Azure/tflint-ruleset-avm/pull/156)
  at `f02257b452c9250ac4cdce0989dc83e16da0560e`; the related public guidance
  merged through
  [Azure-Verified-Modules #2881](https://github.com/Azure/Azure-Verified-Modules/pull/2881).
