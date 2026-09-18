# Catalog request batching constructor fix

- **Status**: complete
- **Started**: 2026-09-18
- **Completed**: 2026-09-18
- **Branch**: `jaredfholgate-fix-catalog-request-batching`

## Outcome

`Invoke-AvmCatalogRequestSet` threw `Cannot find an overload for "new" and the argument count: "1"` on
every catalog HTTP request set, so the `Collect immutable source and registry snapshot` step of the
`Module Metadata Catalog Sync` workflow could never complete.

The fault was introduced with the batching work in #136. `0..($count - 1)` yields an `Object[]`, which
PowerShell cannot bind to the `List<int>(IEnumerable<int>)` constructor, so the pending-index list
failed to construct for *any* batch size. The reported line number pointed at the caller inside
`Invoke-AvmCatalogRequest` rather than the real fault site.

The bug survived review because every existing test mocked `Invoke-AvmCatalogRequestSet`, so the
function body had no coverage at all. This slice fixes the constructor and adds tests that execute
the real body against a stubbed `HttpMessageHandler`.

## Checklist

- [x] Cast the range to `[int[]]` at `ModuleCatalog.Collection.ps1:160`.
- [x] Audit the rest of the repository for the same unsafe generic-collection constructor pattern.
      Line 160 was the only occurrence; every other call either passes a `[StringComparer]` or
      already casts explicitly (for example `[string[]]` at `ModuleCatalog.ps1:713` and
      `RepositoryFileSync.ps1:16,18`).
- [x] Add an `AvmCatalogStubHandler` test double and a `Use-CatalogStubHandler` helper that swaps the
      cached `HttpClient` for one backed by that handler.
- [x] Cover the previously untested batch path: single request, multi-request ordering, a 25-request
      batch that spans concurrency chunks, the empty request set, cross-host batching with
      per-request not-found handling, transient retry, persistent transport fault, and the
      single-request `Invoke-AvmCatalogRequest` wrapper.
- [x] Confirm the new tests fail without the fix.

## Validation

- `Invoke-Pester tests/Pester/Component/ModuleCatalog.Collection.Tests.ps1` — 41 passed, 0 failed.
- Same file with the fix reverted — 34 passed, 7 failed, confirming the new tests are genuine
  regression coverage. The empty-request-set test still passes because that path returns before the
  pending list is built.
- `./build.ps1 pre-commit` — green.

## Follow-up

The HTTP collection path has never run to completion in production, so further latent faults may sit
behind this one. Re-run the workflow after merge and expect to iterate.
