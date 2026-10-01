# Bicep test-only subscription pool selection

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Implement an offline selection contract for the configured BAMI test-only
subscription pool. Parse its exact 28-entry `{name,id}` JSON shape, require an
explicit tenant and both protected Admin and Persistent subscription IDs,
reject malformed, duplicate or protected entries, and select a member with a
uniform random index. Do not treat a structurally valid pool as proof of
Azure account identity, management-group membership or deployment authority.

This slice adds no public command parameter, cloud query, runtime Create
path, workflow variable, selector or registry CI change. In particular,
the Bicep execution variable bundle does not currently publish the Admin
subscription ID; the future runner must receive and verify it explicitly
before using this selection contract.

## Checklist

- [x] Trace the published pool shape and existing Bicep account safeguards.
- [x] Implement a pure, fail-closed BAMI pool validator and random selector.
- [x] Add deterministic mocked selection plus malformed, protected and
      duplicate-input regressions without Azure or MCR access.
- [x] Run targeted checks, the full local gate and coverage, then commit and
      push this slice on the existing review.

## Validation

- Focused `./build.ps1 test -TestName '*Bicep BAMI test subscription pool selection*'`:
  31 passed, zero failed.
- `./build.ps1 pre-commit`: layout and lint passed; 2,104 unit tests passed,
  nine skipped, and 1,046 component tests passed. The 49 test-generated
  warnings came from unrelated mocked repository-management cases.
- `./build.ps1 coverage`: 72.54% (6,009 of 8,284 commands), above the 70%
  floor; 2,104 unit tests passed and nine were skipped.
- New PowerShell files are UTF-8 without BOM and LF; no cloud or MCR calls.

## Blockers or dependencies

This is only a candidate selector. Before subscription-to-group runtime
Create can use it, the selected account and tenant, membership under the
configured test management group, and exclusion of Admin/Persistent targets
must be verified against Azure. The protected Admin ID is not currently
present in the Bicep execution variable bundle. Deployment history is not
a proven recovery store because ARM can automatically prune it, and resource
tags do not exist before Create. A proposed future option is an explicitly
approved test-only durable journal: write the run, target and approved-preview
receipt before Create; claim recovery conditionally after a crash; compare
deployment operations, tags and live inventory; and quarantine ambiguous
resources instead of deleting them or reusing their target. No such store or
equivalent has been approved or created, so cross-group Create remains
disabled. Existing direct resource-group and guarded higher-scope behavior
are unchanged.
