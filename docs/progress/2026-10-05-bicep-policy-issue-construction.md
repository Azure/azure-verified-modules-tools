# Bicep policy issue construction

- Status: complete
- Started: 2026-10-05
- Updated: 2026-10-05
- Branch: current refactor feature branch ([#221](https://github.com/Azure/azure-verified-modules-tools/pull/221))
- Parent: [2026-10-03-avm-authoring-refactor.md](2026-10-03-avm-authoring-refactor.md)

## Outcome

`Invoke-AvmBicepCheckPolicy` repeated a pair of `catch` blocks eight times. The first block passed a known AVM exception's message through; the second replaced any other exception with a fixed safe message. Both blocks built the same issue with the same root. A local `$addFailure` helper now makes that choice once. Each call site still states the exception types whose messages are trusted, so no new exception text reaches users.

Issue codes, messages, severities, baselines and the result shape are unchanged.

## Checklist

- [x] Collapse the paired `catch` blocks into one `catch` per step
- [x] Cover the compiler step's two exception paths: a known AVM tool error is shown verbatim, and any other error is hidden
- [x] Focused policy unit and component tests
- [x] Fix the module catalog staging move flake that failed two consecutive gates
- [x] `./build.ps1 pre-commit`

## Gate flake fix

Two consecutive gates each failed two `ModuleCatalog` component tests. The cause was Windows refusing `Directory.Move` with `Access denied` while antivirus or indexing briefly held handles on newly written staging files. `Move-AvmCatalogStagingDirectory` now retries the move up to five times with a short delay. It retries only while the staging directory is intact and the destination is still absent, so the "never overwrite an existing output" rule is unchanged. On Windows, tests hold a real exclusive file lock to cover: a lock released during the mocked wait, a lock that never releases (bounded failure), and an existing destination (no retry).

## Validation

- Focused policy tests: 41 passed (`BicepPolicy.Component`, `Unit/Private/Engines/BicepPolicy`, `Unit/Public/Invoke-AvmCheckPolicy`).
- `ModuleCatalog.Component.Tests.ps1`: 162 passed.
- First gate: lint and unit tests passed; component tests had 2 failures, both the catalog `Access denied` flake that is now fixed.
- Final `./build.ps1 pre-commit`: passed in 11m11s. Lint took 1m18s. Unit: 2,977 passed (3m59s). Component: 1,280 passed and 1 skipped across six shards (5m52s).