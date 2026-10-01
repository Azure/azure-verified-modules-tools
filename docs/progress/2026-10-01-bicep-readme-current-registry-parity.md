# Bicep README parity on current registry

**Status**: blocked
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Make Bicep build, lint, validation, and README rendering non-restoring under
`AVM_OFFLINE=1`, and report source-less READMEs explicitly without blocking
source-backed rendering. Audit the current registry before crediting pinned
assertion M:651. The current checkout has two concrete README differences;
one external dependency is not cached for an unmodified offline run.
`avm.bicep.convention-incomplete` stays in place. Do not switch registry CI.

## Current comparison inputs

- Registry main checkout: `5c123604fa1da88e3d98e2acb01f4b8a8ea5b4c2`,
  obtained read-only through GitHub into an ignored temporary directory.
- 578 tracked READMEs: 575 alongside `main.bicep`, three source-less
  `avm/ptn/aca-lza/hosting-environment/modules/` children.
- The checked-in Scriban template equals the packaged template at
  SHA-256 `3099E02E1DB7B637F0ABA462E2213C9225DC9769C7000E8CF741F440695DAF34`.
- The previous full frozen comparison was scoped to a different combined
  candidate, not this checkout. Its precisely reviewed Vault difference
  is not a blanket exemption for new drift.

## Current-head comparison

An independent raw-byte comparison with `AVM_OFFLINE=1` selected all 575
source-backed READMEs, rendered 574, and matched 573 exactly. It reported
three source-less READMEs as `NotRendered` warnings, never as generated
matches. The Vault root is the one rendered mismatch: its generated output
adds exactly eight JSON example comment lines (four `Required parameters`
and four `Non-required parameters`) and no other differences. The tracked
SHA-256 is `72BEFB145543D707BA849143ECCB8D4B17EFE2B09385156E6A5CC1B7060D8E01`;
the generated SHA-256 is
`DE837FEEE2890A3BAB192282FB19F5D8FB80A8D7D2315BBF85BF425220890066`.
This is the same *kind* of difference as the frozen comparison, but is
still a real current-head `avm.bicep.docs-stale` result.

The unrendered source-backed path is
`avm/res/azure-stack-hci/virtual-machine-instance/README.md`: its source
references `br/public:avm/res/hybrid-compute/machine:0.6.0`, unavailable
in the local Bicep cache. `docs generate --no-restore` returned BCP190,
which `avm docs` reported as `avm.bicep.docs-render-failed`, not a pass.
The immutable registry release tag for that dependency points to
`5c7c9f9b53c787e5cc1116a713b9981a4f7acdbc`; its `main.bicep`,
`metadata.json`, and `main.json` blobs exactly match current checkout.
An isolated disposable registry worktree used Bicep's `moduleAliasesMock`
to resolve the release-tag source and the tagged `avm-common-types:0.6.0`
source locally. Without restoration, the pinned CLI built the HCI module,
and `avm docs -CheckDrift` rendered its README. Its only difference from
the current tracked file is the Remote reference changing from
`machine:0.4.1` to the authored `machine:0.6.0`; the tracked and generated
SHA-256 hashes are respectively
`C6FD140F63C2473724A316AC18E260479104AC9A724B88EE9D08F5C7D3997EF5`
and `390B2DD76984C9787BAB0FF1670D86EC080731B387908F16698EFB7FA0749A24`.
This locally mocked result identifies actual source/README drift but
does **not** verify the live OCI artifact or replace an unmodified,
fully inspectable current-head comparison.

## Checklist

- [x] Make Bicep build, lint, validation, and README generation
      non-restoring when `AVM_OFFLINE=1`, with mocked arguments and
      failure tests.
- [x] Determine the legacy treatment of source-less READMEs and keep
      those paths visible without claiming generated content.
- [ ] Qualify all 575 current source-backed READMEs with their required
      external dependencies inspectable and resolve the two actual
      differences. The offline comparison and tagged-source diagnostic
      above do not satisfy this gate.
- [x] Independently review the safety changes and remediate the
      uncovered offline lint/validation paths.
- [x] Run unfiltered `./build.ps1 pre-commit` and document the exact
      remaining blockers in this slice and the coverage ledger.

## Validation

- `./build.ps1 test` passed after the mocked offline lint/build
  failure tests were added.
- Unfiltered `./build.ps1 pre-commit` passed all five tasks: layout,
  lint, 1,977 unit tests (nine skipped), and 1,045 component tests
  (one skipped); zero errors and 49 existing negative-path warnings.
- An independent reviewer found direct lint and validation Bicep
  invocations without `--no-restore`; both are now guarded by
  `AVM_OFFLINE=1`, and a second focused review found no significant
  issue in that correction.

## Blockers or dependencies

The frozen renderer comparison in
[Bicep README generation](2026-09-28-bicep-readme-generation.md) does not
qualify current registry main. The exact Vault eight-comment difference
is an explicitly documented comparison exception in the implementation
spec, but `avm docs -CheckDrift` still flags that tracked README as stale;
no broad drift exemption was added. The HCI reference change is an
unapproved difference requiring an upstream README correction. An
authoritative published `machine:0.6.0` dependency must be available
for an unmodified, current-head comparison before removing the
coverage failure. No live MCR/Azure request was made in this development
slice.
