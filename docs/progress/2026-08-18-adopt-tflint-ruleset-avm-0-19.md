# Adopt TFLint ruleset AVM 0.19

**Status**: complete
**Started**: 2026-08-18
**Updated**: 2026-08-18
**Branch**: `jaredfholgate-adopt-ruleset-v0-19`

## Outcome

Updated `Avm.Authoring` for `Azure/tflint-ruleset-avm` 0.19.0 while retaining
the managed TFLint 0.64.0 binary and strict GitHub Artifact Attestation plugin
installation. Preserve deprecated-interface notice findings in structured and
rendered output without changing warning or error gating.

## Checklist

- [x] Review upstream 0.19.0 rule and interface changes from pull requests 147
      and 150 against packaged configs, fixtures, wrappers, and tests.
- [x] Upgrade all AVM plugin pins to 0.19.0 without weakening attestation-only
      installation.
- [x] Update canonical fixtures for the required 0.19.0 interface additions
      without rewriting byte-for-byte upstream provenance fixtures.
- [x] Add wrapper coverage for deprecated-interface notices and unchanged
      warning/error status behaviour.
- [x] Add strict real-binary integration expectations for 0.19.0 installation,
      version reporting, interface enforcement, canonical pass, and notice
      pass-through.
- [x] Update directly related stubs, assertions, README, and changelog.
- [x] Run all available targeted, offline, and pre-commit validation.
- [x] Publish the completed slice on a feature branch and open a pull request.
- [x] After the signed release exists, verify release provenance, run real-binary
      integration and the full local gate, complete this slice, and mark the pull
      request ready.

## Validation

- Verified the final [v0.19.0 release](https://github.com/Azure/tflint-ruleset-avm/releases/tag/v0.19.0)
  targets `65b64c30542365d1360d7dc40c8c8652568e702c`, contains
  `checksums.txt` and all 12 platform archives, and is neither draft nor
  prerelease.
- Verified the release-triggered
  [`sign-checksums` run](https://github.com/Azure/tflint-ruleset-avm/actions/runs/32168886221)
  completed successfully for the release commit.
- `./build.ps1 layout`: passed.
- `./build.ps1 test`: 959 passed, 8 skipped, 0 failed.
- `./build.ps1 pre-commit`: passed; 959 unit tests passed with 8 skipped and all
  28 component tests passed. PSScriptAnalyzer reported only its existing warning
  baseline after two automatically retried transient engine exceptions.
- `./build.ps1 integration`: 22 total, 20 passed, 2 fixture-applicability skips,
  0 failures, and 0 errors in the completed validation result. The strict
  Windows AMD64 TFLint integration installed the attested v0.19.0 plugin,
  reported the expected version, enforced all five required interfaces, passed
  the canonical fixture, and preserved the deprecated lock notice without
  failing the warning threshold. A separate local attempt encountered an
  expired Azure CLI refresh token in the unrelated AzureRM policy-plan fixture;
  the completed integration result used valid credentials.
- `git diff --check`: passed.

## Blockers or dependencies

None. The signed release and its checksum attestation are available.
