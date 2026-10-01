# Packaged Bicep metadata qualification

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-metadata-independence`

## Outcome

Qualify the Bicep metadata/source correction through a locally staged
installable module in a fresh PowerShell process, against pinned, disposable
real registry source. Preserve the boundary between local distribution
qualification and an independently signed, published release.

## Checklist

- [x] Identify and stage the repository-standard distribution artifact offline.
- [x] Exercise independent descriptions, source requirements, and both telemetry
      wiring forms from the staged module against pinned registry scopes.
- [x] Record an appropriate focused packaging regression or standard offline
      smoke entry point without touching registry source.
- [x] Run focused checks and the full local pre-commit gate.
- [x] Prepare this bounded slice for commit, push, and an accurate review update.

## Validation

`.\scripts\Test-AvmBicepMetadataPackage.ps1 -RegistryPath <pinned-sparse-checkout>`
ran offline with `AVM_OFFLINE=1` and `AVM_NO_AUTO_INSTALL=1`. The script used
`.\build.ps1 build`, zipped its staged `out/Avm.Authoring` module, unpacked it
into a disposable versioned `PSModulePath`, and imported that **local, unsigned
module package** by name in a fresh PowerShell process. It did not import
`src/` for its validation. The stage has version `0.0.0`; this is not an
ESRP-signed or published installable release.

The registry checkout came only from cached local Git objects and was detached
at `6eb8e6ff3fe2910043d184da4192799752271ecf`. The sparse paths were
`avm/res/azure-stack-hci` and `avm/res/storage/storage-account`, with no network
fetch. All five direct `Test-AvmModuleMetadata -CheckSource` checks passed with
zero issues: HCI cluster, its metadata-only arc-setting/extension child, HCI
logical-network, storage-account, and the nested blob-service/container child.
Each of the four source-backed scopes has a Bicep description distinct from
its JSON description and canonical registry telemetry wiring. The exact
`Test-AvmMetadataModules` metadata step passed with zero issues for the sparse
monorepo (**22** scopes), HCI cluster (**3**), HCI logical-network (**1**),
and storage-account (**14**).

On disposable copies of pinned storage source (never the checkout), the
package preserved legacy telemetry wiring without a write plan, proposed
canonical wiring for an authored literal prefix without altering authored
name/description, and rejected a conflicting variable. Missing Bicep name
or description declarations, either same-scope source marker without source,
and telemetry-emitting source without a metadata prefix all failed as intended.
The registry checkout remained clean. The entrypoint removes its package and
probe directories; the pinned sparse checkout is removed after qualification.

The new entrypoint had no PSScriptAnalyzer findings under the repository's
settings. `.\build.ps1 pre-commit` passed layout and lint; 1,908 unit tests
passed (9 skipped) and 934 component tests passed. The gate reported zero
errors and 49 warnings from existing test fixtures. The change adds only the
offline entrypoint and this progress record; no module implementation or
registry files changed.

## Blockers or dependencies

No live Azure, MCR, deployments, registry writes, release, or merge. This
sparse-checkout metadata-only smoke is not a whole-registry or full pre-commit
qualification, and the local distribution artifact does not replace the
signed released-package qualification gate.
