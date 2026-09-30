# Bicep publication-aware convention checks

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Cover pinned registry compliance assertions M:1722, M:1928 and M:2022 for
versioned root and child Bicep scopes. Read the complete published tag set
from each module's exact MCR tag-list endpoint; compare changelog headings
with published tags or the next target version, require the target heading
when publication is pending, and couple versioned parents to child version
resets. Determine the target patch from the pinned registry's upstream
release tags and the current version change against upstream main. Treat
unavailable, uninspectable, untrusted or offline inputs as named failures,
not as an unpublished module. A missing module is acceptable only with an
exact not-found response from its tag-list endpoint.

## Checklist

- [x] Implement a strict, read-only MCR tag-list client and publication
      context without modifying the target checkout or fetching refs.
- [x] Enforce the changelog and parent/child assertions for every versioned
      scope, including initial publication and nested children.
- [x] Add mocked HTTP/Git positive and negative tests; make no live MCR,
      Azure or upstream Git calls during development.
- [x] Review independently, update the pinned coverage ledger, run the
      unfiltered `./build.ps1 pre-commit`, commit and push to the existing
      review.

## Validation

The MCR client accepts only its constructed HTTPS module tag-list path
and same-path pagination links, requires attributable responses and
canonical, unique version tags, and treats only an exact registry
`NAME_UNKNOWN` 404 as unpublished. Invalid pagination, redirects, invalid
responses, transport errors and `AVM_OFFLINE=1` fail with named diagnostics.
The read-only Git context checks the official upstream main hash against
trusted local tracking refs; missing or stale refs and release tags fail
closed. A changed `version.json` resets the target patch to zero only
when its major.minor does not decrease. Published older changelog headings
and a pending target are checked independently on each versioned scope.
An established child's major.minor increase requires each versioned
ancestor to increase and reset its target patch.

Mocked HTTP and Git unit tests cover valid/paginated tags, 404 shape,
wrong host/path, malformed versions, offline/transport failures, tag
calculation, a current trusted origin ref alongside stale upstream,
downgrades and out-of-range upstream versions. Component fixtures cover
published and unpublished headings, the target heading, offline and
unavailable MCR, and changed root/child versions. Independent review
identified a downgrade reuse, uncaught out-of-range upstream version,
and a stale-ref precedence bug; all were fixed and tested. Its concern
about child-only publishing paths applies to the pinned registry
M:1722 `Get-ModulesToPublish` subtree behavior, so an explicit regression
test preserves it rather than silently changing the contract.

The unfiltered `./build.ps1 pre-commit` passed layout and lint, 1,957
unit tests (nine skipped), and 1,016 component tests (one Windows-only
skip). The 49 warnings arose from unrelated exercised negative paths.
No live MCR/Azure requests or upstream `git ls-remote`/`git fetch`
commands were made during development; registry scripts were inspected
via GitHub REST.

## Blockers or dependencies

README/API-version rules, resource-folder singularization and both accepted
telemetry source forms remain separate fail-closed convention families.
Neither registry CI nor published packages change in this slice.
