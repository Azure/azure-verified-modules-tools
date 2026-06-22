# Smoke tier

Spec [§18](../../../docs/avm-implementation-spec.md) defines three test tiers:

| Tier        | Filesystem | Network | Tag           | Run by                                  |
| ----------- | ---------- | ------- | ------------- | --------------------------------------- |
| Unit        | None (no `TestDrive`) | None | _(untagged)_ | `./build.ps1 test`, `./build.ps1 coverage`, every PR via `ci` |
| Integration | Real (`TestDrive`) + stub binaries on `PATH` | None | `Integration` | `./build.ps1 integration`, every PR via `ci` |
| Smoke       | Real | **Real** | `Smoke` | `./build.ps1 smoke` (release branches / on-demand only) |

## What lives here

Tests under `tests/Pester/Smoke/` exercise the real production code paths
that hit the real internet — currently the `Invoke-AvmHttp` download
primitive and (eventually) `Install-AvmTool` against the published
GitHub release artefacts in `src/Avm.Authoring/Resources/tools.lock.psd1`.

The smoke tier is the canary that catches:

- Lock-file SHA drift (an upstream re-publish would surface here long
  before a user reported it).
- Mirror / proxy regressions (`AVM_MIRROR` rewrite path).
- TLS / network-stack regressions on a runner OS.
- GitHub release URL template changes (the `{os}`, `{arch}`, `{ext}`
  placeholders in `urlTemplate`).

## How they run

Every smoke test **must** be tagged `-Tag 'Smoke'`. The `smoke` build
task filters on that tag and is **not** part of `pre-commit` or the
`ci` composite — it only runs when explicitly invoked.

```pwsh
./build.ps1 smoke
```

The expectation per spec is "release branches only" — wire this into a
GitHub Actions workflow that runs on `release/**` or on `workflow_dispatch`,
not on every push.

## Authoring rules

- Tag every `It` / `Describe` with `-Tag 'Smoke'`.
- Treat the network as the System Under Test — keep payloads small
  (prefer the smallest managed tool, currently `terraform-docs` at
  ~5 MB compressed).
- Use real, stable URLs. Anything you assert on (URL, SHA) must come
  from `src/Avm.Authoring/Resources/tools.lock.psd1` so a vendor
  re-publish is caught here, not in production.
- Honour `$env:AVM_OFFLINE` — when it is `'1'`, skip the test (don't
  fail). The smoke runner should never be the reason an offline build
  blocks.
- Use `TestDrive` for every download target so smoke runs leave no
  residue under the user's cache.
