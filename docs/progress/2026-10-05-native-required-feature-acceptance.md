# Native required-feature acceptance

**Status**: blocked
**Started**: 2026-10-05
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Qualify the repository-root required-feature manifest through the public native
Bicep e2e command before retiring the registry workflow's forwarding tests.
Existing reader tests cover parsing and selection, but existing native workflow
tests only use a standalone module manifest.

## Checklist

- [x] Exact root-map selection through native e2e, without forwarding sibling entries.
- [x] Explicit and pool-selected subscriptions, with the requested tenant active during registration.
- [x] Malformed and competing declarations fail before any Azure operation.
- [x] Safe focused Pester 5/6 execution and the full local gate.
- [ ] Commit, push, and provide the registry owner with exact retirement evidence.

## Safety

Reuse the native workflow fixture's mocked Azure, compiler and subprocess
boundaries. No cloud deployment, registration, sign-in or host configuration.

## Evidence

`Invoke-AvmTestE2e.ScopedBicep.Component.Tests.ps1` now drives the real public
command with module files under `avm/res/compute/virtual-machine` and a separate
repository-root map. Two positive cases assert exactly one selected feature,
the explicitly requested tenant and explicit/pool-selected subscription at
registration, registration before validation, and restoration of the prior
context. Four negative cases reject malformed JSON, a root array, a malformed
unselected entry and competing module/root manifests before compilation,
Azure dependency setup, context selection or cleanup-state creation.

- Pester 5.7.1 focused native workflow: 26 passed, no skipped tests.
- Pester 6.2.0 focused native workflow: 26 passed, no skipped tests.
- Pester 6.2.0 `.\build.ps1 pre-commit`: green; 1,504 component tests passed,
  one pre-existing skip; layout, lint and unit checks passed.
- Full gate elapsed: 10m04.60s; not a comparable performance measurement.

## Publication blocker

The preceding qualified CI commit is blocked by the current OAuth App's
missing `workflow` scope. These qualified tests can be committed locally but
cannot provide a published retirement reference until the coordinator arranges
user-approved workflow-authorized authentication. Do not retire registry tests
based only on this local evidence.
