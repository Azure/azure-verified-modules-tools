# Bicep current-registry README qualification

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Completed**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Qualify README regeneration at a recorded registry-main commit using actual
published dependency bytes, without source aliases, fake cache entries,
registry file writes, Azure calls, or a broad restore. Keep the convention
coverage failure until every source-backed README and every warning/error
is accounted for.

## Approved boundary

The user approved one public dependency: `br/public:avm/res/hybrid-compute/
machine:0.6.0` from Microsoft's public MCR, including only its manifest,
config, and layers required for that exact artifact. Use the pinned Bicep
CLI's normal cache mechanism and verify digest provenance. No tag enumeration,
other public module restore, Azure authentication, publication, registry CI
cutover, release, or manual workflow dispatch is approved.

The registry source is pinned to a Git commit for repeatable comparison.
Run documentation drift checks with `AVM_OFFLINE=1` so every Bicep build and
render uses `--no-restore`; retain and report every source-less README,
failed render, warning, and stale file. The earlier audit at
`5c123604fa1da88e3d98e2acb01f4b8a8ea5b4c2` was incomplete:
574/575 source-backed READMEs rendered; Vault differed by eight generated
comment lines and HCI had an uncached dependency. Registry main later fixed
the historical HCI README version reference via
[Azure/bicep-registry-modules#7430](https://github.com/Azure/bicep-registry-modules/pull/7430).

## Verified published input

The canonical Bicep cache folder
`%USERPROFILE%\.bicep\br\mcr.microsoft.com\bicep$avm$res$hybrid-compute$machine\0.6.0$`
was absent before restoration. The pinned CLI is Bicep `0.47.16`
(`3f73e1a234`), matching `src/Avm.Authoring/Resources/avm.pins.jsonc`.
An ignored temporary `machine-restore.bicep` referenced only the approved
module; its explicit `br/public` alias mapped to
`mcr.microsoft.com/bicep`. `bicep restore` succeeded without
authentication or any other module reference.

An HTTPS GET to only
`https://mcr.microsoft.com/v2/bicep/avm/res/hybrid-compute/machine/manifests/0.6.0`
returned OCI status 200 and `Docker-Content-Digest`
`sha256:1be3caa1aa3d48b799e798cd979c8cb7429bee3fd1fc86a7943a9576ea0cc75d`.
The response bytes, Bicep cache `manifest`, and cache `metadata.manifestDigest`
match that SHA-256. The manifest describes the Bicep module artifact, config
size two with digest
`sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a`
(`{}` bytes), compiled `main.json` size 17,631 with digest
`sha256:cb411b4051a8e8005b6779185a37584ea09e237e56de0aa0ef8dda0d30de6f1a`,
and `source.tgz` size 7,285 with digest
`sha256:0a44d22e3498b5cebb6399ee54d0a39f50cb6816617c8aabb01f6ab4bb698659`.
Independent SHA-256 calculations on both cached layers and `{}` matched
all three descriptors. No tag list, Azure endpoint, unrelated module restore,
or registry write was used.

## Current registry source and targeted checks

A clean, disposable, shallow GitHub checkout pins registry main at
`82bab0404566557b9fb5efdc9780bb5ce438030b`. It has 578 tracked READMEs:
575 alongside `main.bicep` and three source-less
`avm/ptn/aca-lza/hosting-environment/modules/` children. HCI README SHA-256
is `390B2DD76984C9787BAB0FF1670D86EC080731B387908F16698EFB7FA0749A24`,
matching its corrected `machine:0.6.0` reference. Vault README SHA-256
remains `72BEFB145543D707BA849143ECCB8D4B17EFE2B09385156E6A5CC1B7060D8E01`.

With `AVM_OFFLINE=1`, `AVM_NO_AUTO_INSTALL=1`, the current worktree module,
and pinned Bicep `0.47.16`, an unmodified HCI module check selected/rendered
one README and passed with no issues. The Vault scope selected/rendered four
READMEs and passed with exactly one warning on the root:
`avm.bicep.docs-example-comments` for eight generated JSON-example comment
lines. Both checks used real published cache bytes without `moduleAliasesMock`
or source substitutions; the disposable registry checkout stayed clean.
These targeted checks do **not** qualify the remaining source-backed READMEs.

## Full-registry comparison

At the same clean registry pin, `Invoke-AvmDocs -CheckDrift` with
`AVM_OFFLINE=1` and `AVM_NO_AUTO_INSTALL=1` selected and rendered all 575
source-backed READMEs with pinned Bicep `0.47.16`; no restore or source
alias was used. Status was `pass`, with no changed files, stale READMEs,
render errors, or unclassified issues. The only rendered warning is
`avm.bicep.docs-example-comments` on Vault for eight generated lines.
Three `avm.bicep.docs-no-source` warnings separately name source-less
hosting-environment children.

A second non-writing render returned all 575 generated contents for an
independent raw-byte comparison. Exactly 574 generated READMEs matched
the tracked bytes; only `avm/res/key-vault/vault/README.md` differed.
The generated Vault output adds exactly four `    // Required parameters`
and four `    // Non-required parameters` lines, with every other byte
unchanged. Its tracked SHA-256 is
`72BEFB145543D707BA849143ECCB8D4B17EFE2B09385156E6A5CC1B7060D8E01`;
the generated SHA-256 is
`DE837FEEE2890A3BAB192282FB19F5D8FB80A8D7D2315BBF85BF425220890066`.
The provenance-backed comparator independently restricts the accepted
omissions to producer-owned, complete JSON-example comment pairs.

All three source-less README files have no `main.bicep`; their disk bytes
match the pinned Git blobs, rather than being counted as generated:

| Path under `avm/ptn/aca-lza/hosting-environment/modules/` | Git blob |
| --- | --- |
| `container-apps-environment/README.md` | `27ece2b8c39fa28cd79f17b4968cf5773ae3e246` |
| `spoke/README.md` | `f472066c43530d4a6dc1d9fb76dd92921cbf37af` |
| `supporting-services/README.md` | `730490c2b8bb98293cf5fd1098aba0cd1f6d59f8` |

The checkout remained clean after both passes. README assertion M:651
is now covered in the composed `avm pr-check` through its required docs
step; a clean Bicep convention result no longer reports an invented
coverage error. Actual render errors, changed prose/code/types/outputs,
missing scopes, and required rule violations still fail.

## Checklist

- [x] Inspect the exact canonical public-MCR Bicep cache candidates and
      record the local pinned CLI version.
- [x] Obtain or verify only the approved published artifact with TLS and
      digest provenance; stop on unexpected authentication or dependency.
- [x] Pin an unmodified registry checkout and run a complete offline
      source-backed README drift comparison with named issues and counts.
- [x] Update the assertion ledger and review body with the exact evidence
      and limits; commit/push any focused documentation change.
- [x] Run the full local gate after the convention coverage change.

## Validation

Scoped real Bicep docs checks at the current registry pin: HCI 1/1 passed
with no issues, Vault 4/4 passed with exactly one eight-line
`avm.bicep.docs-example-comments` warning. The HTTPS MCR tag manifest
response, Bicep cache metadata, and SHA-256 checks of its two local
layers and two-byte config all match their OCI descriptors. The
source checkout remained at the pinned commit and had no dirty files.
Both complete 575-source-backed renders passed without restore. The
independent comparison found 574 byte-exact matches and only the proven
eight-line Vault exception; all three source-less paths match tracked
Git blobs. The unfiltered `./build.ps1 pre-commit` passed all five tasks:
layout, lint, 2,008 unit tests (nine skipped), and 1,049 component tests
(one skipped), with zero errors and 49 existing negative-path warnings.
An independent read-only review of the coverage closure found no
significant issues. The review body records the exact audit evidence;
automatic hosted checks are evaluated separately after push.

## Blockers or dependencies

No missing published module or README render blocker remains at this pin.
An incomplete or unavailable future render still fails explicitly. This
qualification does not authorize switching registry CI or bypassing its
published source-pending catalog gate; integrated installable-package
smoke and the independently reviewed metadata/test-tier work remain
separate migration prerequisites.
