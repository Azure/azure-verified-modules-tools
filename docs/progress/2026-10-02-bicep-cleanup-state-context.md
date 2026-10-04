# Bicep cleanup state and Azure context

**Status**: complete
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Integrate the native cleanup foundation with explicit dependency and Azure
context checks, ordered batch removal, and retained non-secret cleanup
state. Use the caller's existing Azure PowerShell authentication; do not
export tokens, log in automatically, or create a new storage service.
Temporary context changes must be process-scoped and restored.

The runner remains responsible for normal cleanup. The reaper is a
fallback, including loss of a runner before an artifact upload completes.
The state file contains deployment and resource identifiers and cleanup
status, never parameter values or deployment outputs.

## Checklist

- [x] Provide native dependency and matching-identity preflight that the
      deployment runner must call before submission; runner wiring is separate.
- [x] Preserve and restore the caller's Azure context, including failures.
- [x] Remove exact discovered resources in dependency order with retries,
      preserving post-removal work and unresolved targets.
- [x] Write and read a validated non-secret state file atomically.
- [x] Cover persistence, interrupted cleanup, secret exclusion, context
      preservation and partial failure with offline controls.
- [x] Run the full development gate, commit and push.

## Validation

The focused standard development gate passed layout, lint, 111 unit
controls and 32 component controls. A subsequent catalog control also
requires the separate Az.Subscription dependency before imports; it is
included in the successful full gate. Tests use fake Azure commands and
real temporary files, not live deployment or deletion.

Recovery controls include recorded Databricks managed groups, original
Recovery Services settings, missing child metadata, blocked descendants,
post-only retries, cross-subscription context selection, cancellation at
each cleanup phase, fatal restoration failure, incomplete discovery,
ownership/cloud/tenant mismatches, relative caller-selected paths and
idempotent resumption after completion. Every CLI cleanup call checks the
selected subscription's account before lookup, deletion or purge.

Installed command metadata was inspected in a fresh local process without
executing any Azure commands. All required command parameters or aliases
matched eleven installed module versions from the Az 15.5.0 bundle.
The native Recovery Services model exposes SoftDeleteFeatureState as
System.String, matching the state reader. Az.Subscription 0.12.0 was not
installed locally; it is explicitly required, and no installation was
performed. The dependency floors are based on public package metadata.

The preceding native cleanup foundation is committed as `b0c3993`.
The ordinary unfiltered `.\build.ps1 pre-commit` gate passed: layout and
lint had no findings, 2,646 unit tests passed with nine existing skips,
and 1,293 component tests passed with one existing skip. There were zero
test failures or build errors and 82 warnings from exercised warning/error
paths. The existing analyzer wrapper recovered after four transient
NullReferenceException retries; no analyzer rule or retry policy changed.

The implementation is retained in the existing draft
[tools #219](https://github.com/Azure/azure-verified-modules-tools/pull/219).

## Boundaries and dependencies

Full deployment workflow parity remains tracked in
[the parent work record](2026-10-02-bicep-workflow-parity.md).
No production action, live Azure qualification, automatic module
installation, release, or registry CI cutover is authorized by this slice.

These helpers remain private. They do not yet replace the existing e2e
runner, create a public recovery command, or upload an Actions artifact.
The authentication comparison covers matching CLI/native account IDs;
managed-identity representations and live SDK behavior are not qualified
by mocked controls or local command-metadata inspection.
