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

Shipped. Four Terraform-ecosystem stubs landed 2026-05-27 alongside
`tests/helpers/Install-AvmStubLauncher.ps1` and the first consumer
`tests/Pester/Integration/Invoke-AvmPreCommit.Terraform.Integration.Tests.ps1`.

| Stub                  | Argv accepted                                              | Lock version |
| --------------------- | ---------------------------------------------------------- | ------------ |
| `terraform.ps1`       | `--version`, `fmt …`, `init …`, `validate …`               | `1.15.3`     |
| `tflint.ps1`          | `--version`, `--recursive --format=json`                   | `0.55.1`     |
| `terraform-docs.ps1`  | `--version`, `markdown table …`                            | `0.20.0`     |
| `conftest.ps1`        | `--version`, `test …` (emits `[]` for pass)                | `0.68.2`     |

The argv-log file (`$env:AVM_STUB_LOG_DIR`) hinted at above is not yet
emitted — the current consumer only needs the engine wrappers to succeed
end-to-end, which is asserted via the cmdlet output. Add the logging hook
if a future Integration test needs argv-level assertions.

## Pinned-asset fixture pattern

Engines that load APRL / AVMSEC / other policy bundles through
`Read-AvmAssetConfig` + `Resolve-AvmPinnedAsset` (currently just
`Invoke-AvmTerraformCheckPolicy`) need on-disk archives at test time.
The integration harness avoids real downloads by exploiting
`Resolve-AvmPinnedAsset`'s cache-hit fast-path: as long as
`<AVM_HOME>/cache/assets/<name>/<sha>/.verified` plus the resolved Path
both exist, the resolver returns immediately without ever calling
`Invoke-AvmHttp`. The descriptor source URL can be any well-formed
`https://example.invalid/<file>.zip` value (parser validates shape, not
reachability) and the SHA256 just has to match `^[0-9a-f]{64}$`. The
Terraform integration test pre-stages `avm-policy-aprl` and
`avm-policy-avmsec` this way; mirror the pattern for any future
pinned-asset engine fixtures.

Bicep ecosystem stubs (`bicep.ps1`, etc.) will land alongside the first
Bicep Integration test that needs them.
