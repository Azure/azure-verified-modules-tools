# Adopt TFLint ruleset AVM 0.21

**Status**: blocked
**Started**: 2026-08-20
**Updated**: 2026-08-20
**Branch**: `jaredfholgate-adopt-tflint-0-21`

## Outcome

Adopt the assumed `Azure/tflint-ruleset-avm` `v0.21.0` release and its
`azapi_replace_triggers_refs` omission semantics without claiming release
provenance before the release exists.

## Checklist

- [x] Update packaged TFLint configuration and the mirrored AVM plugin pin.
- [x] Remove empty `replace_triggers_refs` fixture declarations.
- [x] Document the optional, non-empty replacement-trigger contract.
- [x] Cover version generation, fixture omission, and the unreleased attestation
      gate in structural, unit, component, and integration tests.
- [x] Run the local build and applicable integration validation.
- [ ] Publish the branch and open a blocked pull request.

## Validation

- `./build.ps1 pre-commit` passed after the packaged configuration, pin,
  fixture, unit, and component updates.
- `./build.ps1 integration` confirmed that
  `https://api.github.com/repos/Azure/tflint-ruleset-avm/releases/tags/v0.21.0`
  returns the expected `404 Not Found`. The affected real `pr-check` cases and
  dedicated plugin-attestation case are now explicitly skipped while the pin is
  `unreleased`; independent real-binary integration coverage remains enabled.

## Blockers or dependencies

- `v0.21.0` is assumed and has not been released or attested. The real TFLint
  plugin download and artifact-attestation integration test must remain gated
  until release assets, checksums, and provenance can be verified.
- The ruleset implementation is under review in
  [tflint-ruleset-avm #156](https://github.com/Azure/tflint-ruleset-avm/pull/156)
  at `f02257b452c9250ac4cdce0989dc83e16da0560e`; the related public guidance
  is under review in
  [Azure-Verified-Modules #2881](https://github.com/Azure/Azure-Verified-Modules/pull/2881).

## Post-release finalization

1. Verify that `v0.21.0` has final release assets, checksums, and a completed
   GitHub Artifact Attestation.
1. Change `tflintPluginReleaseStatus.avm` in `avm.pins.jsonc` to `released`.
1. Run `./build.ps1 integration` to execute the real `pr-check` and
   artifact-attestation coverage against `v0.21.0`.
1. Record the verified release provenance and integration result, then remove
   the pull request's blocked status.
