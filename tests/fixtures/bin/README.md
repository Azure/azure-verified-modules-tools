# Stub-binary harness for the Integration tier

`tests/Pester/Integration/` tests must not hit the real network, but they
do exercise real subprocesses against real filesystems. This directory
holds the cross-platform stubs that stand in for the managed CLIs
(`bicep`, `terraform`, `tflint`, `terraform-docs`) so the engine wrappers
can be validated end-to-end without the real binaries.

## Convention

For each managed tool name `<tool>` we ship a single PowerShell stub
script `<tool>.ps1` here. A small helper (added in a follow-up slice)
materialises it as a launcher named exactly `<tool>` (no extension on
Linux/macOS, `<tool>.cmd` shim on Windows) inside a `TestDrive`
sub-folder, then prepends that folder to `$env:PATH` for the test's
duration.

The stub itself should:

- Accept the same argv contract the engine wrappers actually use
  (e.g. `bicep format <file>` returns 0 and rewrites the file; failure
  cases come from a single switch like `$env:AVM_STUB_BICEP_EXIT`).
- Record its argv to a file in `$env:AVM_STUB_LOG_DIR` so the test
  can assert on it.
- Stay tiny — anything more than ~50 lines belongs in a real
  Integration test rather than baked into the stub.

## Status

Placeholder. The first slice (2026-05-18) wired the Integration tier
itself (build task, CI step, canary `Process.Tests.ps1` that uses real
`pwsh` as its subprocess) but did not yet need engine stubs. The stubs
land alongside the first engine integration test that requires them.
