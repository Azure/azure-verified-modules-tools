# Bicep distribution package qualification

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-package-qualification`

## Outcome

Qualify one local, unsigned Avm.Authoring distribution built from merged
main `c724bcaf967308b14fbd3a9975cbb015d29e8719`. Import the extracted,
versioned module by name in fresh PowerShell and prove command provenance.
Reuse the existing metadata smoke and the completed
[current-registry README audit](2026-10-01-bicep-current-registry-readme-qualification.md);
do not repeat its 575-file render.

## Checklist

- [x] Inspect standard build/package procedures and existing package smoke.
- [x] Verify pinned local registry objects and published dependency cache.
- [x] Qualify representative real metadata, telemetry, and README behavior.
- [x] Qualify packaged policy/convention/unit routing and post-hook contracts
      with separately labeled offline fixture checks.
- [x] Prove artifact import paths and non-writing real docs checks.
- [x] Run focused standard selectors and the required pre-commit gate.
- [x] Record artifact version/hash, results, and remaining boundaries.
- [x] Prepare the gated slice for commit, push, and current-session review.

## Validation

### Distribution boundary

The extended `scripts/Test-AvmBicepMetadataPackage.ps1` retains its metadata-only
default. Supplying `-DocsRegistryPath` also runs representative real docs and
focused existing contract suites. `-ArtifactDirectory` retains the qualified
unsigned zip and its JSON evidence outside the repository.

```powershell
.\scripts\Test-AvmBicepMetadataPackage.ps1 `
    -RegistryPath <clean-6eb8e6ff-sparse-snapshot> `
    -DocsRegistryPath <clean-82bab040-sparse-snapshot> `
    -AllowWorkingTree `
    -ArtifactDirectory <owned-local-artifact-directory>
```

Snapshots came exclusively from existing local Git objects through the
registry worktree, with no network fetch. Configure the disposable clone
with `core.autocrlf=false` and `core.eol=lf` **before** sparse checkout;
the docs snapshot includes `docs/templates`. The first smoke rejected a
CRLF-converted HCI README as `avm.bicep.docs-stale`; recreating byte-exact
LF snapshots corrected the input, without changing the renderer or
waiving drift.

`.\build.ps1 build` staged version **0.0.0** from merged tools commit
`c724bcaf967308b14fbd3a9975cbb015d29e8719`, plus the explicitly recorded
working-tree producer correction below. The local unsigned
`Avm.Authoring-0.0.0-c724bca-local.zip` has SHA-256
`977d88c0952ef53cb60c25e3d0218a88059c34dd553cc459ab6d2a7c59159362`.
All **302** extracted module files matched their staged SHA-256 hashes.
The original c724-only archive
`4341ebb06e411b4a940a9fa857ef72522e1098fd918fa5a82834f8b3f1fb040b`
is historical, not the corrected qualification artifact. The only module
source change was `Resources/Scaffolds/Bicep/main.bicep`, SHA-256
`690cde319eef7a983f40e8571f43e5dfad9a75bf926f0d40829ae693393e3baf`.
`-AllowWorkingTree` explicitly records uncommitted module paths instead
of misrepresenting them as committed c724 source; the default still
requires clean module source.

Fresh `pwsh -NoProfile -NonInteractive` process **76940** imported
`Avm.Authoring -RequiredVersion 0.0.0` by name from:

```text
%TEMP%\avm-bicep-metadata-package-46e2131ac29f43bb96d9e7010a2bded5\modules\Avm.Authoring\0.0.0\Avm.Authoring.psm1
```

The module path/base and **42** command definitions (29 exports and 13
private metadata/docs/policy/convention/unit/post-hook helpers) resolved
inside that extracted artifact, never `src` or a global module.
The `avm` alias resolved to `Invoke-Avm`. The packaged child Pester runner
was present at `Resources/bicep/Invoke-AvmPesterSuite.ps1`, SHA-256
`886525f647206054a65252d60e42c7eb58ab496d290c145bb1dfc44c7097fa05`.
Its real child-process unit routing passed. Temporary extraction and
probe fixtures were removed; the zip and detailed JSON evidence remain
in the session's artifact directory.

### Real pinned metadata and docs

At `6eb8e6ff3fe2910043d184da4192799752271ecf`, all five direct metadata
checks passed without issues: HCI cluster, its intentional metadata-only
arc-setting/extension child, HCI logical-network, storage-account, and
the nested container. Four source descriptions differed legitimately
from JSON descriptions. The exact composition metadata step passed
for the sparse monorepo (**22** scopes), cluster (**3**), logical-network
(**1**), and storage (**14**).

On disposable source copies, the packaged public initialization command
applied new canonical telemetry wiring while preserving authored name
and description. Both actual and WhatIf legacy initialization were
byte-preserving and planned no migration. Six named negative controls
rejected conflicting telemetry variables, missing source name/description,
same-scope `version.json` or `main.json` without source, and an
instrumented utility without a JSON telemetry prefix.

At `82bab0404566557b9fb5efdc9780bb5ce438030b`, packaged
`Invoke-AvmDocs -CheckDrift -IncludeRenderedContent` with pinned Bicep
**0.47.16** rendered **seven** READMEs: HCI virtual-machine-instance
(1), Vault root/access-policy/key/secret (4), and storage container plus
immutability-policy (2). Six were byte-exact. Vault retained exactly the
known eight producer-owned JSON-example comment differences and the
single `avm.bicep.docs-example-comments` warning. Its tracked/generated
hashes matched the completed audit:
`72befb145543d707ba849143eccb8d4b17efe2b09385156e6a5cc1b7060d8e01` /
`de837feee2890a3bab192282fb19f5d8fb80a8d7d2315bbf85bf425220890066`.
All **23** selected source/README files retained their bytes and timestamps;
both registry snapshots stayed clean.

The canonical `$`-encoded published `machine:0.6.0` cache retained manifest
`sha256:1be3caa1aa3d48b799e798cd979c8cb7429bee3fd1fc86a7943a9576ea0cc75d`,
compiled layer
`cb411b4051a8e8005b6779185a37584ea09e237e56de0aa0ef8dda0d30de6f1a`,
and source layer
`0a44d22e3498b5cebb6399ee54d0a39f50cb6816617c8aabb01f6ab4bb698659`.
Local hashes and cache metadata matched the previously verified published
input; no restore, source alias, new MCR request, or dependency install ran.
The earlier full 575-file audit is reused, not repeated here.

### Separately labeled fixture contracts

The corrected extracted package passed **38 unit** and **46 component** selected
contracts, with no failures or skips, through standard
`.\build.ps1 test,component -TestName ...` selectors in another fresh
process. Only already installed InvokeBuild, Pester, and exact
powershell-yaml 0.4.12 were copied into the isolated module search path.
The shared test import helper preserves ordinary source-based developer
tests, but package runs import by name and reject a foreign module base
or command definition.

These checks cover required policy/convention/docs result contracts,
module-owned unit routing, and fake-process post-hook success/failure,
cancellation, cleanup ordering, integration exclusion, and dry-run behavior.
Compiler/PSRule/Azure fixture checks are **not** real policy or deployment
qualification. The actual packaged API-spec and MCR publication readers
separately rejected `AVM_OFFLINE=1` with explicit unavailable-input errors.
No full current-registry `avm pr-check` pass is claimed.

### Authorized producer correction and real compiler regression

The first ordinary gate exposed a merged producer/validator mismatch.
The shipped scaffold already used the canonical `telemetryIdPrefix`
reader but retained the description approved only for the legacy reader.
The historical scaffold test also fabricated legacy compiled wiring.
The creator explicitly authorized the tightly coupled producer correction
within this slice, without weakening validation or deployment guards.

Only the new root scaffold's description changed to the registry's exact
`Optional. Enable/Disable usage telemetry for module.` The validator,
legacy `avmTelemetryIdPrefix`/`$.telemetryIdPrefix` reader, legacy description,
prefix-first name checks, and existing authored modules remain unchanged.
The component fixture now reflects canonical compiled wiring; existing
legacy and mixed-description negative controls remain strict.

`BicepScaffoldTelemetry.Integration.Tests.ps1` generates an actual local
module through `Initialize-AvmModule`, compiles its source with the cached
pinned Bicep `0.47.16` using `--no-restore`, and runs the actual compiled
telemetry validator. Five cases passed with no skips: generated canonical
scaffold, byte-preserved legacy reader/description, and rejected mixed
description, hardcoded prefix, and non-prefix-first name. The same five
real compiler checks passed against the extracted corrected package in
the separate fresh process through standard `.\build.ps1 integration`
selectors. These are real offline compiler checks, not canned compiled
JSON or Azure execution.

### Development gate

The smallest standard build and focused existing selectors passed first.
Package smoke offline flags were scoped to child processes, never globally
forced for the ordinary repository gate. The four smoke/import-helper
scripts passed the repository's analyzer settings with zero findings,
after documented retries for transient analyzer NullReferenceException.

The initial `.\build.ps1 pre-commit` passed layout, lint, and **2,534 unit tests**
(nine skips). Components reported **1,260 passed, one failed, one skipped**.
The failure is the unchanged merged scaffold/convention contract in
`tests/Pester/Component/BicepConvention.Component.Tests.ps1:510-543`,
`accepts the shipped scaffold telemetry declaration and description as a
distinct supported form`. Its focused standard selector independently
reproduced the failure:

```powershell
.\build.ps1 component -TestName `
    'Bicep static convention checks.accepts the shipped scaffold telemetry declaration and description as a distinct supported form'
```

The shipped `Resources/Scaffolds/Bicep/main.bicep` uses the new canonical
`telemetryIdPrefix` reader but retains
`Optional. Enable/disable usage telemetry for this module.` The test
still fabricates compiled `avmTelemetryIdPrefix` and its legacy deployment
name. It reports `avm.bicep.telemetry-parameter`,
`avm.bicep.telemetry-name`, and `avm.bicep.telemetry-prefix`.
`Test-AvmBicepConventionCompiledTelemetry.ps1:46-65` independently ties
the shipped description to the legacy reader only; canonical input is
required to use `Optional. Enable/Disable usage telemetry for module.`
Correcting only the stale compiled fixture would therefore still expose
the canonical scaffold/description mismatch.

No assertion was weakened or skipped to hide this failure. The one-line
producer fix and truthful canonical fixture corrected it without changing
the validator. Focused canonical/legacy/mixed-description component checks
and all five real scaffold compilation cases passed. The rebuilt package
passed the representative metadata/docs/provenance and 84 fixture contracts,
plus the five separately labeled real compiler cases. The final ordinary
`.\build.ps1 pre-commit` passed all five tasks: layout, lint, **2,534 unit
tests** (nine skips), and **1,261 component tests** (one skip), with zero
errors and 82 nonfatal warnings from existing mocked negative paths.
The smoke/import-helper scripts and new real compiler regression passed
the repository analyzer settings with no findings. No code commit/push
preceded the green gate. Both pinned snapshots stayed clean and were removed
after qualification; the historical and corrected unsigned archives and
JSON evidence remain only in the session's artifact directory.

## Blockers or dependencies

No missing real-module input remains for this bounded qualification.
The merged scaffold/convention mismatch was resolved by the explicitly
authorized producer-only correction. No validator relaxation, deployed
resource allowlist, cleanup, ShouldProcess, schema, release, or CI change
was needed.

Version 0.0.0 is an unsigned local distribution, **not** the signed/published
v0.20.0 release or a new release. Broad Bicep deployment parity and the
required online publication/API/policy inputs remain separate boundaries.
No schema/version bump, global install, release/publish/tag, live Azure,
CI cutover, scope enablement, reaper/permissions/baseline change, merge,
or manual workflow dispatch is part of this slice.
