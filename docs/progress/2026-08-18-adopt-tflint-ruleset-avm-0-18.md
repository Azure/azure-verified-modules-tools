# Adopt TFLint ruleset AVM 0.18

**Status**: complete
**Started**: 2026-08-18
**Updated**: 2026-08-18
**Branch**: `jaredfholgate-adopt-tflint-v0-18`

## Outcome

Upgrade the managed TFLint binary to 0.64.0 and the vendored
`Azure/tflint-ruleset-avm` plugin to 0.18.0. Require GitHub Artifact Attestation
for plugin installation, keep unsupported platform handling explicit, and prove
the packaged configuration installs and executes the pinned ruleset.

## Checklist

- [x] Refresh the TFLint 0.64.0 pin and supported-platform SHA-256 values.
- [x] Upgrade all AVM plugin pins and require `signature = "attestation"`.
- [x] Prevent drift from the attestation-only signing contract in tests.
- [x] Update directly related fixtures, documentation, and changelog entries.
- [x] Run targeted tests, real-binary integration, and `./build.ps1 pre-commit`.
- [x] Commit, push, and open the GitHub pull request.

## Validation

- `./build.ps1 test`: 958 passed, 8 skipped.
- `./build.ps1 lint`: passed with the repository's existing analyzer warnings.
- Focused real-binary integration against the Azure fixture: 17 passed and 1
  expected skip. This installed TFLint 0.64.0 from the managed pin, installed
  `ruleset.avm (0.18.0)` from the packaged configuration using GitHub Artifact
  Attestation, executed the consolidated `terraform_variable_separate` rule,
  and passed the fixture's complete `pr-check` lint path.
- `./build.ps1 pre-commit`: passed in 3m 44s (layout; lint; 958 unit tests
  passed, 8 skipped; 28 component tests passed).

## Blockers or dependencies

No implementation blockers. The upstream v0.18.0 release and checksum-signing
run were verified before this slice started.

An unfiltered integration run also reached the credential-dependent AzureRM
policy fixture. Its two policy tests could not complete because the local Azure
CLI refresh token had expired; no reauthentication or production action was
attempted. The TFLint attestation proof and both Azure fixture lint paths
completed successfully.
