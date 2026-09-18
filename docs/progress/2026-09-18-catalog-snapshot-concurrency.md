# Catalog snapshot concurrency, retry and diagnostics

- **Status:** complete
- **Date:** 2026-09-18
- **Branch:** `jaredfholgate-snapshot-step-perf`

## Outcome

The `Collect immutable source and registry snapshot` step of the module metadata
sync workflow took roughly 80 minutes and then failed outright when a single
request timed out. Collection now issues its requests concurrently with bounded
per-host limits and retries transient failures, so one slow response no longer
destroys a completed run. The workflow also publishes the exact source CSV rows
that would be removed, and every long-running script reports progress.

## What changed

1. Replaced the sequential `Invoke-WebRequest` transport in
   `ModuleCatalog.Collection.ps1` with `Invoke-AvmCatalogRequestSet`, a batched
   `HttpClient` seam with per-host concurrency limits and exponential-backoff
   retry that honours `Retry-After`. `Invoke-AvmCatalogRequest` is now a thin
   single-request wrapper over it, so all validation and status semantics are
   preserved in one place.
1. Restructured the four heavy collection paths (Bicep registry, Terraform
   registry, GitHub enrichment, Terraform source snapshots) into global batch
   phases instead of per-module request loops. Roughly 20,000 sequential calls
   now run as a small number of concurrent batches.
1. Added `Write-AvmCatalogProgress` and used it across the collection,
   generation and publication scripts, including per-batch counts and
   percentage milestones.
1. Added `Format-AvmCatalogCsvRowRemoval` and
   `Write-AvmCatalogCsvRowRemovalReport`. Row removals are now logged as a
   readable per-file table and written to `csv-row-removals.csv` and
   `csv-row-removals.json`, uploaded as workflow artifacts on both the collect
   and publish jobs (including on failure).
1. Renamed the workflow and its stage/step display names to drop the `[AVM]`
   prefix, matching the other workflows in this repository.

## Checklist

- [x] Diagnose the timeout and the sequential request volume
- [x] Confirm no cheaper batch API endpoints exist upstream
- [x] Concurrent, retrying transport with preserved error semantics
- [x] Batch the four heavy collection paths
- [x] Progress logging across the catalog scripts
- [x] CSV row-removal report in CSV and JSON, published as an artifact
- [x] Workflow naming aligned with the other workflows
- [x] `./build.ps1 pre-commit` green

## Validation

`./build.ps1 pre-commit` passes: layout OK, lint clean, 1602 unit tests and 688
component tests passing with no failures. All touched files are LF, UTF-8
without BOM.

## Follow-up

Real-world timing has not been measured against production yet. A
`workflow_dispatch` run with `plan_only: true` would confirm the improvement.
