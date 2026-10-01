# Bicep test recovery receipt

**Status**: blocked
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Superseded by the decision to pursue recovery without a new per-run journal.
The following was a private, offline prototype for a single Create-only
subscription-scoped Bicep test resource. Bind the test run and case, selected
test-only subscription and tenant, explicit management-group placement
evidence, deterministic deployment name, validated preview resource ID and
type, exact staged template digest, preparation/expiry timestamps and
`Prepared` state. A digest protects the exact serialized receipt bytes.

The proposed injected persistence writer would acknowledge the receipt before
an injected Create action can run. Recovery must reject missing, corrupt,
foreign, nonterminal or expired operation evidence as `CleanupPending`; even
complete operations require separate live identity and inventory checks
before any deletion. The callback and evidence are fakes in tests; this
prototype did not select storage, implement a live evidence adapter, or wire
the existing runner to these helpers. The four helper files and their focused
test were preserved as uncommitted session artifacts outside module and test
discovery. Do not restore, load, or commit them under the current no-journal
design.

## Checklist

- [ ] Reuse the current Bicep pool, scoped resource and deployment ID guards.
- [ ] Create and validate the typed receipt and explicit target evidence.
- [ ] Require an exact, durable-writer acknowledgement before calling a
      mocked Create; exercise failures and cancellation after commit.
- [ ] Quarantine ambiguous or expired recovery observations, including
      missing step outputs, without deleting.
- [ ] Run focused tests, full local gate and coverage; commit and push this
      slice on the existing review.

## Validation

- Focused offline prototype tests: 48 passed; lint passed.
- The full pre-commit gate was stopped after layout, lint and 2,159 unit
  passes (nine skipped), before component tests; this prototype was **not**
  committed or pushed. No Azure or MCR call was made.

## Blockers or dependencies

Superseded: no separate run-record persistence is authorized. Current
subscription-, management-group- and tenant-scoped Create guards remain
fail-closed wherever ownership or recovery cannot be proven; do not infer
deployment parity from the paused prototype.

No Azure membership query or durable-store implementation is present.
Mocked evidence only proves the validation rules, not real BAMI membership
or authority. The live runner must supply verified account and subscription
placement evidence, a trustworthy receipt writer with conditional commit
semantics, an explicitly approved expiry policy, and recovery/live ownership
checks before this can gate Create. Resource groups, nested deployments,
management groups and tenant-root operations remain outside this receipt
subset; no existing Bicep e2e runtime behavior changes here.
