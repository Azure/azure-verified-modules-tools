# Checkout-free Bicep publication data

**Status**: blocked
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

Remove the last required registry checkout from publication preparation.
Reuse trusted current local Git objects when present; otherwise read only
module main/version data at the independently verified upstream commit.
No common scripts, rules or configuration are downloaded.

## Checklist

- [x] Add a pinned, cached module-data path for independent consumers.
- [x] Preserve strict unavailable-history failures and publication semantics.
- [x] Exercise real preparation in copied-package acceptance.
- [x] Run focused Pester 5/6 acceptance and the full gate.
- [x] Record final ownership map and capability evidence; commit locally.

## Evidence

Pester 5.7.1 and 6.2.0 each pass 17 focused publication cases and five independent
package compliance cases. The final ordinary Pester 5 gate passes layout, lint,
units and 1,563 components (one existing skip), in 8m57s. This is qualification,
not an equivalent-work performance claim.

Independent consumers run the actual Git-state and publication-target helpers.
Only upstream transports are simulated: pinned `ls-remote` main, immutable raw
module data, and the API/MCR input catalogs. The positive package test requires
exactly 187 passing native/authored cases, no issues, and the copied package's
compliance path. It observes exactly two module-data HTTP reads (version/main)
and zero clone/fetch/checkout/show/ls-tree/diff commands. Four independent
metadata/telemetry/README mutations fail with located error diagnostics.

The cached public-data path preserves changed/unchanged source comparison,
descendant publishing changes, next-patch calculation and downgrade rejection.
Unavailable, redirected, malformed and false-not-found responses fail explicitly.
Current trusted local Git objects retain their existing efficient path.
The final boundary correction uses pinned remote data for stale trusted refs
as well as absent refs. Unavailable or unverifiable remote data still fails.
No external assertion definitions are fetched.

The coordinator's final audit found that README configuration still required
a canonical caller-owned copy. This was not a genuine customization boundary:
the exact template hash prohibited changes. Rendering now defaults to the
packaged template without writing caller config or templates. Explicit template
configuration retains its existing strict validation. The independent package
acceptance no longer creates documentation configuration or copies Scriban.

`PrivateData.AvmCapabilities.BicepPackagedCompliance = 1` now identifies the
qualified default native convention/metadata/README plus authored-unit route.
It does not imply PSRule, e2e, a published release or live workflow cutover.

## Blockers

Publishing remains unauthorized because of the existing workflow-scope hold.
