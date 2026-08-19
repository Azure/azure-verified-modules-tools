# Refresh external tool pins

**Status**: complete
**Started**: 2026-08-19
**Updated**: 2026-08-19
**Branch**: `jaredfholgate-fix-managed-files-version`

## Outcome

Refresh every externally sourced runtime dependency to its latest stable
release, regenerate integrity hashes through the sanctioned pin-update script,
and remove duplicated tool versions from test stubs.

## Checklist

- [x] Compare every managed tool, policy bundle, and TFLint plugin with upstream.
- [x] Make stub launchers derive tool and plugin versions from `avm.pins.jsonc`.
- [x] Refresh outdated versions and SHA256 hashes with `Update-AvmPins.ps1`.
- [x] Update vendored TFLint configuration for current plugin releases.
- [x] Review intervening upstream release notes and breaking changes.
- [x] Run targeted integration coverage and `./build.ps1 pre-commit`.
- [x] Commit and push the additional slice to the existing pull request.

## Validation

- Latest stable release inventory:
  - Bicep `0.30.3` -> `0.46.1`
  - Conftest `0.68.2` -> `0.69.0`
  - mapotf `0.1.8` -> `0.1.9`
  - terraform-docs `0.20.0` -> `0.24.0`
  - Terraform TFLint ruleset `0.12.0` -> `0.15.0`
  - AVM TFLint ruleset `0.19.0` -> `0.19.1`
  - Terraform `1.15.8`, TFLint `0.64.0`, and policy-library-avm
    `v1.0.0` were already current.
- `Update-AvmPins.ps1` downloaded official release assets or checksum files,
  regenerated all affected platform hashes, and passed `Test-AvmPins`.
- Every Windows amd64 tool installed into an isolated `AVM_HOME`, executed
  `--version`, and reported the pinned version. mapotf `0.1.9` retained a valid
  Authenticode signature.
- TFLint installed the AVM `0.19.1` and Terraform `0.15.0` plugins with
  artifact attestation; both appeared in `--version`, and the canonical fixture
  linted with zero issues.
- The first pull-request integration run completed every real-tool workflow but
  exposed one remaining assertion pinned to TFLint `0.64.0` and AVM ruleset
  `0.19.0`. The integration test now derives the tool and both plugin versions
  from `avm.pins.jsonc`.
- Release-note review found no incompatible invocation changes in the surfaces
  used here. Terraform ruleset `0.15.0` changes multiline comment enforcement
  and adds Terraform 1.15 support; the canonical fixture passed the new rule.
- `./build.ps1 test`: 977 passed, 0 failed, 8 skipped.
- `./build.ps1 component`: 28 passed, 0 failed.
- `./build.ps1 pre-commit`: layout, lint, unit, and component passed.
- `git diff --check`: passed.

## Dependencies and blockers

None.
