# Terraform runtime regression fixes

**Status**: blocked
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-terraform-runtime-regression-fixes`

## Outcome

Restore clean-runtime metadata validation through the shared configured tool
prerequisite mechanism, including PowerShell modules. Resolve the applicable
binary and module dependencies before either composite command starts its first
step. Keep standalone commands on the same mechanism, exact pins, offline and
installation controls, and the default module-upgrade guard.

Correct Retry-After handling, elapsed-duration rounding, and the obsolete
disabled TFLint output-rule override without suppressing unknown or enabled
rules. Update only the Terraform executable pin to the verified stable 1.16.5.

Support version-only `.avm/tool-version-overrides.json` for known dependencies,
using trusted packaged download definitions. The user explicitly requested no
author-supplied checksums: only named overrides bypass pinned verification,
including same-version entries. Warn before composite step 1 with the source
file and packaged/selected versions; use a separate unverified cache. Normal
pins retain their checksum checks. Recognized Bicep monorepos use only their
root file, including commands targeting individual modules.

Baseline is `b226e361e041c5124f5ee11d9c8c8f2b0d1e20f5`, the main squash of
[#221](https://github.com/Azure/azure-verified-modules-tools/pull/221).
No matching regression branch or review existed at the initial check.

## Checklist

- [x] Read the progress protocol, active records, agent contract and standards.
- [x] Verify the clean current-main base and rename this app-managed branch.
- [x] Implement shared binary/PowerShell prerequisites and composite preflight.
- [x] Implement root-scoped version overrides, warnings and cache isolation.
- [x] Correct Retry-After, duration formatting and obsolete TFLint configuration.
- [x] Rotate Terraform to 1.16.5 with official platform checksums.
- [x] Cover clean packaged runtime, pins, offline/install failures and ordering.
- [x] Run focused build routes and the prescribed full local gate.
- [x] Build the candidate, commit/push, and hand its SHA and package to the parent.
- [ ] Record the parent's full canary matrix and finalize the new review.

## Validation

The isolated package integration passes with only `$PSHOME/Modules` initially
available: real metadata acceptance/rejection, the packaged Bicep Pester runner,
YAML parsing, and PSRule baseline discovery acquire the configured packages.
A second fresh process passes offline with automatic installation disabled,
using the same verified cache. No Azure plans or deployments run in this test.

The final unfiltered gate passes layout/lint, 3,070 unit cases (nine existing
skips), and 1,417 component cases (one existing skip). An exact `b226e361`
baseline run passed 1,383 component cases and the same skip: all 1,384 baseline
case/result identities are retained, plus 34 new prerequisite cases. NUnit
comparison normalizes unordered argument serialization and preserves duplicate
identities. The earlier 1,563-case record predates the upstream merge.

An additional Pester 6.2.0 probe found an assembly collision with the runtime
pin. Build, lint and isolated test workers now bootstrap the same configured
Pester through the shared resolver. Focused qualification passes with the newer
version also available: 55 unit cases, 67 component cases, clean-package
integration, and the final full gate. The loaded-version guard gives
fresh-session guidance before work begins. All tests use `.\build.ps1`;
broad integration is excluded.

Qualified source candidate `d1f5e463962c762da6c64e620e4b351faaa1d7a9` is
committed and pushed. Its frozen package and SHA-256 inventory of all 403 files
were handed to the parent. Draft
[#229](https://github.com/Azure/azure-verified-modules-tools/pull/229) awaits
the full canary evidence.

## Blockers or dependencies

Source qualification is complete. Final qualification depends on the parent's
complete Terraform canary matrix against the frozen candidate; record the full
matrix before closing this slice.
The user authorized the parent to use existing credentials against the BAMI
test tenant for plan/policy checks only, not apply/destroy, deployment, provider
registration or access changes. DevOps-pool examples also need organization/PAT
inputs. The parent's authenticated CDN baseline is blocked by the provider's
prohibition on creating retired CDN endpoints, not retired-rule parsing.
The checksum bypass is a user-directed security exception requiring the
repository's SFI review/sign-off before merge/release; no sign-off is recorded.
This source branch performs no authenticated cloud operations. No release,
merge, deployment, credential change, host-security change, or companion Bicep
workflow/registry rollout is authorized.
