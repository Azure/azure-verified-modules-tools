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

Shipped. Three Terraform-ecosystem stubs landed 2026-05-27 alongside
`tests/helpers/Install-AvmStubLauncher.ps1` and the first consumer
`tests/Pester/Integration/Invoke-AvmPreCommit.Terraform.Integration.Tests.ps1`.

| Stub                  | Argv accepted                                              | Lock version |
| --------------------- | ---------------------------------------------------------- | ------------ |
| `terraform.ps1`       | `--version`, `fmt …`, `init …`, `validate …`               | `1.15.3`     |
| `tflint.ps1`          | `--version`, `--recursive --format=json`                   | `0.55.1`     |
| `terraform-docs.ps1`  | `--version`, `markdown table …`                            | `0.20.0`     |

The argv-log file (`$env:AVM_STUB_LOG_DIR`) hinted at above is not yet
emitted — the current consumer only needs the engine wrappers to succeed
end-to-end, which is asserted via the cmdlet output. Add the logging hook
if a future Integration test needs argv-level assertions.

Bicep ecosystem stubs (`bicep.ps1`, etc.) will land alongside the first
Bicep Integration test that needs them.
