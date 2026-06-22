# `config/` — vendored upstream tool configuration

This directory holds **configuration consumed by the `Avm.Authoring` engines at
run time** that is *mirrored from an upstream Azure source* rather than authored
here. It is deliberately kept **separate from the PowerShell module**
(`src/Avm.Authoring/`) because these files are destined to become the canonical
copy once this module ships — at which point the upstream copies are expected to
be removed and this directory becomes the source of truth.

> **Why not under `src/Avm.Authoring/Resources/`?** Module resources are
> Avm.Authoring-owned assets. These configs are *governance-owned* and tracked
> against an upstream pin until ownership transfers here. Keeping them at the
> repo root makes the provenance, the pin, and the sync obligation obvious.

---

## `config/mapotf/pre-commit/` — mapotf transform configs

The nine `*.mptf.hcl` files run by `mapotf transform` during `avm pre-commit`
(and re-run as the drift check during `avm pr-check`). Together they implement
the full AVM Terraform block-ordering / hygiene / file-partitioning contract
(the former `avmfix` behaviour catalogue — see
[`docs/quality-standards.md`](../docs/quality-standards.md) Appendix C/J).

| Provenance | |
| --- | --- |
| Upstream repo | [`Azure/avm-terraform-governance`](https://github.com/Azure/avm-terraform-governance) |
| Upstream path | `mapotf-configs/pre-commit/` |
| Pinned commit | `7f8c4ee4d68095310ddd8722f9cc27d32a0de82c` (2026-06-16) |
| Vendored on | 2026-06-19 |
| Upstream licence | MIT (same as this repo) |

**Files (9):** `avm_headers_for_azapi`, `main_telemetry_tf`,
`move_misplaced_blocks`, `order_module_attrs`, `order_resource_attrs`,
`order_resource_meta`, `required_provider_versions`, `sort_outputs`,
`sort_variables` (all `.mptf.hcl`).

### How it is consumed

```text
mapotf transform   --mptf-dir config/mapotf/pre-commit --tf-dir <module>
mapotf clean-backup --tf-dir <module>
```

The directory contains **only** `*.mptf.hcl` files so it can be passed straight
to `--mptf-dir` with no filtering. `Invoke-AvmTerraformTransform` resolves this
path (the transform engine — Slice G).

### Sync obligation (temporary mirror)

Until `Avm.Authoring` is released, this bundle is a **mirror** of the governance
repo and must be kept in sync with it. Re-sync and review the diff with:

```pwsh
# Re-mirror at the recorded pin (overwrites the in-tree copy):
./scripts/Update-AvmMapotfConfig.ps1

# Move the pin forward to the tip of governance main:
./scripts/Update-AvmMapotfConfig.ps1 -Ref main

# CI / drift gate — fail (exit 1) if the vendored copy has drifted:
./scripts/Update-AvmMapotfConfig.ps1 -Check -Ref main
```

When intentionally moving the pin, update **both** the `-Ref` default in
[`scripts/Update-AvmMapotfConfig.ps1`](../scripts/Update-AvmMapotfConfig.ps1)
and the *Pinned commit* / *Vendored on* rows above, then commit the refreshed
configs together.

**End state:** once this module owns the canonical configs, the upstream
`mapotf-configs/pre-commit/` directory is removed and the sync obligation ends —
this directory is then edited directly.
