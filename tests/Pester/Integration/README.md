# Integration tier

Spec [§18](../../../docs/avm-implementation-spec.md) defines three test tiers
of increasing realism:

| Tier        | Filesystem | Network | Tag           | Run by                                  |
| ----------- | ---------- | ------- | ------------- | --------------------------------------- |
| Unit        | None (no `TestDrive`) | None | _(untagged)_ | `./build.ps1 test`, `./build.ps1 coverage`, every PR via `ci` |
| Component   | Real (`TestDrive`) + stub binaries on `PATH` | None | `Component` | `./build.ps1 component`, every PR via `ci` |
| Integration | Real | **Real** | `Integration` | `./build.ps1 integration` (PR via the `integration` job in the `ci` workflow / on-demand) |

## What lives here

Tests under `tests/Pester/Integration/` exercise the real production code
paths that hit the real internet and real third-party binaries — no stubs,
no mocks. Currently:

- **`Http.Tests.ps1`** — the `Invoke-AvmHttp` download primitive against a
  published GitHub release artefact (the smallest tool we manage,
  `terraform-docs`).
- **`Invoke-AvmTerraform.RealBinaries.Integration.Tests.ps1`** — the full
  Terraform `pre-commit` / `pr-check` chains end to end against the on-disk
  fixture modules using the actual pinned binaries (`terraform`,
  `terraform-docs`, `tflint`, `conftest`, `mapotf`) downloaded into an
  isolated `AVM_HOME`, plus real Terraform provider downloads.

The integration tier is the canary that catches:

- Lock-file SHA drift (an upstream re-publish would surface here long
  before a user reported it).
- Mirror / proxy regressions (`AVM_MIRROR` rewrite path).
- TLS / network-stack regressions on a runner OS.
- GitHub release URL template changes (the `{os}`, `{arch}`, `{ext}`
  placeholders in `urlTemplate`).
- Real-binary composition drift — a wired engine that passes against the
  stub launchers (Component tier) but breaks against the actual tool.

## How they run

Every integration test **must** be tagged `-Tag 'Integration'`. The
`integration` build task filters on that tag and is **not** part of
`pre-commit` or the `ci` composite — it only runs when explicitly invoked.

```pwsh
./build.ps1 integration
```

In CI this tier is driven by the `integration` job in the `ci` workflow, which
runs on `pull_request` and `workflow_dispatch` (not on merge to `main`). The
job can target a single fixture per matrix leg via
`$env:AVM_INTEGRATION_FIXTURE`; with the var unset, a local run covers every
fixture in one process.

## Authoring rules

- Tag every `It` / `Describe` with `-Tag 'Integration'`.
- Treat the network and the real binaries as the System Under Test — keep
  payloads small (prefer the smallest managed tool, currently
  `terraform-docs` at ~5 MB compressed) where a smaller surface still proves
  the path.
- Use real, stable URLs. Anything you assert on (URL, SHA) must come
  from `src/Avm.Authoring/Resources/tools.lock.psd1` so a vendor
  re-publish is caught here, not in production.
- Honour `$env:AVM_OFFLINE` — when it is `'1'`, skip the test (don't
  fail). The integration runner should never be the reason an offline build
  blocks.
- Skip cleanly (never fail red) when a host constraint blocks a real binary
  (e.g. Windows Defender quarantining the `mapotf` Go binary on an
  un-elevated dev box). CI adds the necessary exclusion so it gets a real
  pass instead of a skip.
- Use `TestDrive` (or an isolated temp `AVM_HOME`) for every download target
  so integration runs leave no residue under the user's cache.
