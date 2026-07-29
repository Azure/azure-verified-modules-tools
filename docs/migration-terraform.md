# Migrating AVM Terraform modules to the `Avm.Authoring` CLI

This guide is for maintainers of an AVM Terraform module repo
(`terraform-azurerm-avm-res-*` and friends) who want to move from the
governance-repo tooling stack — `./avm` shell shim, runtime-downloaded
`Makefile`, `mcr.microsoft.com/azterraform` container, and the
`porch-configs/` pipelines — over to the `Avm.Authoring` PowerShell
module that lives in this repo.

This module is **largely wired today** for the Terraform ecosystem.
Concretely: `format`, `lint`, `test`, `docs`, `check policy`, and
`check convention` are real engine invocations (the first five against
upstream binaries, `check convention` against the in-module rule
framework that ships 7 built-in rules covering the kept grept policies
plus a hook for per-repo `<root>/.avm/rules/*.psd1` extensions);
`transform` is a stub step that reports `skipped` while the supply-chain
decision in `docs/progress.md` § *Phase 2 §2 supply-chain audit* is
open. The full status matrix is in [§ 5 Engine status](#5-engine-status)
below.

For the live single-source-of-truth status of every phase and slice,
see [`docs/progress.md`](progress.md). When this guide and `progress.md`
disagree, `progress.md` wins.

---

## 1. Why migrate

The legacy AVM Terraform tooling assumes a Docker- or Podman-managed
container, a repo-local `Makefile` that downloads itself from
`avm-terraform-governance@main` at runtime, and a `./avm` Bash + PWSH
shim. That works well in CI but is heavy on a contributor workstation:
container runtime to install, repo-local writeable `Makefile` to keep
in sync, and a custom CA story for corporate networks.

`Avm.Authoring` replaces that with a single PowerShell module:

- **One install**: `Install-Module Avm.Authoring` (or `Import-Module`
  from a clone). No Docker, no Podman, no `make`, no governance-repo
  download at module-load time.
- **One CLI**: every workflow is an `Invoke-Avm…` cmdlet (also
  available as the short verb form, e.g. `avm pre-commit`). The
  cmdlets compose: `avm pre-commit` chains four engines, `avm pr-check`
  chains seven, and each engine is also runnable standalone.
- **Same upstream binaries**: every engine shells out to the canonical
  tool (`terraform`, `tflint`, `terraform-docs`, `conftest`) — no
  alternate implementation, no re-implementation drift. The module
  pins each tool's version in `Resources/tools.lock.psd1` and downloads
  the official archive on first use into a per-user cache.
- **Same upstream policies**: APRL and AVMSEC are referenced exactly as
  they are upstream; the module fetches the bundles at the version the
  repo pins via `.avm/config.json`.

The one thing that is still legacy-only today is documented in
[§ 6 What's not migrated yet](#6-whats-not-migrated-yet) — `transform`
(needs `mapotf`), which is blocked on the Go-tool packaging decision.

---

## 2. Install

Requirements:

- **PowerShell 7.4 or newer** (Core only; Windows PowerShell 5.1 is
  unsupported).
- Network access to download upstream tool archives on first use, or
  pre-populated `$env:AVM_HOME/cache/` if you're working offline.

Install from PSGallery (when published):

```pwsh
Install-Module -Name Avm.Authoring -Scope CurrentUser
Import-Module Avm.Authoring
```

Or, from a clone of this repo:

```pwsh
git clone https://github.com/Azure/azure-verified-modules-tools.git
Import-Module ./azure-verified-modules-tools/src/Avm.Authoring/Avm.Authoring.psd1
```

No Go toolchain is required for any wired engine; the module downloads
prebuilt release binaries by their pinned SHA256.

---

## 3. Drop-in workflow mapping

This is the head-to-head translation for the legacy entry points an
AVM Terraform module repo exposes today. The right-hand column shows
the `Avm.Authoring` verb you call instead.

### From `Makefile` targets

| Legacy target             | Replacement                                          |
| ------------------------- | ---------------------------------------------------- |
| `make pre-commit`         | `avm pre-commit -Ecosystem terraform`                |
| `make pr-check`           | `avm pr-check -Ecosystem terraform`                  |
| `make docs`               | `avm docs -Ecosystem terraform`                      |
| `make tf-test-unit`       | `avm test unit -Ecosystem terraform`                 |
| `make tf-test-integration`| `avm test integration -Ecosystem terraform`          |
| `make test-examples`      | `avm test e2e -Ecosystem terraform`                  |
| `make globalsetup`        | _No global equivalent — see [§ 6](#6-whats-not-migrated-yet)_ |
| `make globaltearown`      | _No global equivalent — see [§ 6](#6-whats-not-migrated-yet)_ |

> (¹) Bare `avm test` (no tier) runs `terraform init -backend=false`
> then `terraform validate -json` against the module root, and is the
> validate-only step wired into `pre-commit` and `pr-check`. The
> `terraform test`-based tiers are separate commands: `avm test unit`
> runs `tests/unit/*.tftest.hcl`, `avm test integration` runs
> `tests/integration/*.tftest.hcl`, and `avm test e2e` deploys each
> `examples/*` directory. Each tier also fans out over `modules/*`
> submodules and runs an optional isolated `setup.ps1` hook per target.
> An `avm test e2e` apply that fails on region or SKU capacity is
> destroyed and retried (up to `-MaxRetry`, default 2) rather than
> failing the run; add extra retryable patterns with
> `$env:AVM_E2E_RETRY_PATTERN`.

### From `./avm <command>` / `./avm.ps1 <command>`

| Legacy invocation                  | Replacement                                       |
| ---------------------------------- | ------------------------------------------------- |
| `./avm fmt`                        | `avm format -Ecosystem terraform`                 |
| `./avm validate`                   | `avm test -Ecosystem terraform`                   |
| `./avm tflint`                     | `avm lint -Ecosystem terraform`                   |
| `./avm docs`                       | `avm docs -Ecosystem terraform`                   |
| `./avm conftest`                   | `avm check policy -Ecosystem terraform`           |
| `./avm pre-commit`                 | `avm pre-commit -Ecosystem terraform`             |
| `./avm pr-check`                   | `avm pr-check -Ecosystem terraform`               |

One behavioural difference worth knowing when porting a call site:
`./avm pre-commit` exits non-zero whenever it rewrites a file, so callers
run it twice (`./avm pre-commit || ./avm pre-commit` — fix, then verify).
`avm pre-commit` needs no such double-run. It is fail-soft, still reports
`Status='pass'` after a successful regeneration, and names the rewritten
paths per step under `.Steps.Result.Changed`, so a caller can detect
"docs were regenerated" from the result object instead of from an exit
code or a `git status --porcelain` probe.

The container mount, `CONTAINER_RUNTIME`, `CONTAINER_IMAGE`,
`CONTAINER_PULL_POLICY`, and the SSL-cert / `mkcert` plumbing the shim
provides are not needed — the cmdlets call the host's own
`terraform` / `tflint` / `terraform-docs` / `conftest` binaries
through the host's own TLS trust store.

### Composition chains

The composition cmdlets and the exact order of engines they call:

- **`avm pre-commit`** →
  - **Terraform**: `check convention` → `transform` → `format` → `docs` (re-aligned 2026-06-19 to match upstream `porch-configs/pre-commit.porch.yaml`, which runs only transform + docs in pre-commit and keeps `tflint`/validate in pr-check; `lint`+`test` were dropped from this chain because both require `terraform init` and would force pre-commit online — they now live in `avm pr-check` only, mirroring upstream porch)
  - **Bicep**: `format` → `lint` → `test` → `docs` (unchanged)
- **`avm pr-check`** → `format` → `transform` → `lint` → `check policy` → `check convention` → `test` → `docs`

A step that raises `AvmConfigurationException` (e.g. an engine that's
still a stub because the required tool isn't packaged yet, or a policy
asset isn't declared) is reported as `Status='skipped'` and the chain
keeps going. Pass `-StopOnFail` to abort on the first hard failure.

---

## 4. Pinned-asset config

The legacy governance scripts pull policy bundles, mapotf configs,
grept rules, and the merged tflint config from `git::` URLs at module
load time, parameterised by `AVM_PORCH_BASE_URL`, `AVM_MPTF_URL`,
`AVM_GREPT_URL`, `AVM_TFLINT_CONFIG_URL`,
`AVM_CONFTEST_APRL_URL`, and `AVM_CONFTEST_AVMSEC_URL`.

This module replaces those env vars with a per-repo config file at
`<repo-root>/.avm/config.json`, merged with the per-user file at
`$env:AVM_HOME/config/avm.config.json` (or the platform-default config
folder when `AVM_HOME` isn't set). Per-asset, the per-repo value wins.

The minimum config to make `avm check policy` work today (the only
asset-consuming engine that's wired) is:

```json
{
  "schemaVersion": 1,
  "assets": {
    "avm-policy-aprl": {
      "type": "archive",
      "url": "https://github.com/Azure/policy-library-avm/archive/refs/tags/<ref>.tar.gz",
      "sha256": "<64-hex>",
      "subdirectory": "policy-library-avm-<ref>/policy/Azure-Proactive-Resiliency-Library-v2"
    },
    "avm-policy-avmsec": {
      "type": "archive",
      "url": "https://github.com/Azure/policy-library-avm/archive/refs/tags/<ref>.tar.gz",
      "sha256": "<64-hex>",
      "subdirectory": "policy-library-avm-<ref>/policy/avmsec"
    }
  }
}
```

The downloader (`Resolve-AvmPinnedAsset`) verifies the SHA256, caches
the extracted directory under
`$env:AVM_HOME/cache/assets/<name>/<sha256>/`, and reuses it on
subsequent runs. Bundling default APRL/AVMSEC descriptors into the
module itself is a deliberate follow-up; for now both bundles must be
declared per-repo.

The per-example exception walker is built in: any `*.rego` file under
`<repo-root>/examples/*/exceptions/` is automatically picked up and
appended as an extra `--policy` flag to `conftest`. The previous
governance-repo convention (`examples/<name>/exceptions/*.rego`) is
preserved verbatim.

---

## 5. Engine status

The verbs `avm pre-commit` and `avm pr-check` will compose against
exactly this status today.

| Verb                  | Engine binary           | Argv contract                                                                                                                | Wired? | Notes                                                                                                                                            |
| --------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------- | :----: | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `avm format`          | `terraform fmt`         | `fmt -recursive -list=true -write=true <root>`                                                                               |   ✅   | Returns `Changed` list of rewritten files.                                                                                                       |
| `avm lint`            | `tflint`                | `--recursive --format=json` from `cwd=<root>`                                                                                |   ✅   | Exit `2` with `severity=error` issues → `Status='fail'`; warnings flatten into the same `Issues` array.                                          |
| `avm test`            | `terraform validate`    | `init -backend=false -upgrade=false -input=false -no-color` then `validate -no-color -json` from `cwd=<root>`                |   ✅   | Bare `avm test` is validate-only and is the step wired into `pre-commit` / `pr-check`.                                                            |
| `avm test unit`       | `terraform test`        | per target (`<root>` + each `modules/*`): optional `setup.ps1`, then `test -test-directory=tests/unit -no-color -json`       |   ✅   | Fans out over `modules/*`; exit `1` parsed for failing runs; abnormal exit throws. `.env` per target bridged to the subprocess.                  |
| `avm test integration`| `terraform test`        | same as `unit` with `-test-directory=tests/integration`                                                                      |   ✅   | Real providers — needs `az`/creds at runtime (no preflight; documented).                                                                          |
| `avm test e2e`        | `terraform apply`       | per `examples/*` (skip `.e2eignore`): `pre.ps1` → init → apply → `plan -detailed-exitcode` (idempotency) → destroy → `post.ps1` |   ✅   | Real backend; destroy is always attempted best-effort. An apply that fails on capacity is destroyed and retried (`-MaxRetry`, default 2) and logged as a warning. `setup.sh` / `teardown.sh` hooks are rejected. |
| `avm docs`            | `terraform-docs`        | `markdown table --output-file README.md --output-mode inject .` from `cwd=<root>`                                            |   ✅   | Requires `BEGIN_TF_DOCS` / `END_TF_DOCS` markers in `README.md`. Without them, terraform-docs falls back to appending and `Changed` flags it.   |
| `avm check policy`    | `conftest`              | `test --policy <APRL> --policy <AVMSEC> [--policy <exceptions>...] --output json --parser hcl2 .` from `cwd=<root>`          |   ✅   | Needs `avm-policy-aprl` + `avm-policy-avmsec` declared in `.avm/config.json` (see [§ 4](#4-pinned-asset-config)). Otherwise reports `skipped`.   |
| `avm transform`       | `mapotf`                | _engine stub, `AvmConfigurationException` → `skipped`_                                                                       |   ❌   | Blocked: `Azure/mapotf` ships no GitHub binary releases; see [§ 6](#6-whats-not-migrated-yet).                                                   |
| `avm check convention`| _in-module `avm-rules`_ | walks 7 built-in `.psd1` rules under `src/Avm.Authoring/Resources/Rules/` + optional per-repo `<root>/.avm/rules/*.psd1`; aggregates issues |   ✅   | grept is replaced, not ported. Built-in set covers the 5 kept upstream grept policies per Slice B audit (file presence, name normalisation, dir scaffolding, `.gitignore` essentials). `-Fix` flag plumbed through. |

The pinned tool versions live in
`src/Avm.Authoring/Resources/tools.lock.psd1`. Today: `terraform`,
`tflint`, `terraform-docs`, `conftest` (and `bicep` for the unrelated
Bicep engine).

---

## 6. What's not migrated yet

These items are tracked in [`docs/progress.md`](progress.md) and the
status here will lag the canonical checklist by at most one slice.

- **`avm transform`** — needs `mapotf` in `tools.lock.psd1` plus a
  pinned `mapotf-configs` asset. The upstream `Azure/mapotf` repo has
  no GitHub Releases; only `go install` is supported. Blocked on the
  architectural decision in `progress.md` § *Phase 2 §2 supply-chain
  audit* (options A: build-and-host CI, B: new `goModule` lock kind
  requiring `go` on `$PATH`, C: defer §2). Same blocker affects:
- **`avm format` `avmfix` chaining** — the legacy chain is
  `terraform fmt` → `avmfix`. The `avmfix` follow-up step is the same
  blocker (`go install`-only). `avm format` today runs only the
  `terraform fmt` step.
- **Global setup / teardown** — the porch `globalsetup` /
  `globaltearown` targets that provisioned one shared fixture for a
  whole test run have no direct equivalent. State and secrets are
  provisioned per target instead: `avm test unit` / `integration` run
  an optional `tests/<tier>/setup.ps1` per module, and `avm test e2e`
  runs an optional `pre.ps1` / `post.ps1` per example. Setup hooks must
  be PowerShell — a `setup.sh` / `teardown.sh` is rejected with an
  `AvmConfigurationException`.
- **Default APRL / AVMSEC descriptors bundled with the module** — for
  now both must be declared per-repo in `.avm/config.json`. Bundling
  the canonical Azure-owned descriptors is a deliberate follow-up
  slice.
- **`terraform plan` → conftest** — today `avm check policy` runs
  against the HCL source via `--parser hcl2`. The plan-JSON path
  (`terraform plan -out=tfplan && terraform show -json | conftest test --parser json`)
  is a follow-up; it needs real provider auth, so it's out of scope
  for the unit-tier coverage today.
- **Governance-side fleet automation** — three workflows in
  `Azure/avm-terraform-governance` shell out to the repo-local `./avm`
  shim rather than to this module: `dependabot-precommit.yml` (added
  upstream 2026-07-22 — runs pre-commit against open Terraform Dependabot
  PR branches across the fleet and pushes the regenerated docs back so
  the module's own PR check goes green), `pre-commit-cron.yml`, and
  `governance-test.yml`. All three are central to the governance repo and
  are deliberately **not** synced into module repos, so there is nothing
  to port into this repo. The migration dependency runs the other way: a
  module repo that deletes `./avm` drops out of their coverage until they
  are taught to `Install-PSResource Avm.Authoring` and call
  `avm pre-commit`. The synced
  `managed-files/root/.agents/skills/avm-terraform-module-development/SKILL.md`
  likewise still documents `./avm` to coding agents.

---

## 7. Environment variables

The module reads only the env vars it owns:

| Env var                     | Effect                                                                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `AVM_HOME`                  | Override the per-user root. All six folders (`config`, `cache`, `data`, `state`, `tools`, `logs`) live under `$AVM_HOME/<folder>`.    |
| `AVM_OFFLINE`               | When `1`, every `Invoke-AvmHttp` call refuses to download and throws `AvmConfigurationException`. Local caches are still consulted.   |
| `AVM_MIRROR`                | An `https://` prefix used to rewrite canonical tool/asset URLs through a corporate mirror. Lock SHA256s still apply unchanged.        |
| `AVM_NO_CONSOLE_CONFIG`     | When `1`, the module skips the import-time `[Console]::OutputEncoding` + `$OutputEncoding` UTF-8 setup on Windows. See [CONTRIBUTING.md § 9](../CONTRIBUTING.md#9-os-specific-notes). |
| `AVM_LINT_MAX_ATTEMPTS`     | Number of retry attempts for the documented transient PSSA `NullReferenceException`. Build-time only; not used by runtime cmdlets.    |

Container-only env vars from the legacy stack (`CONTAINER_RUNTIME`,
`CONTAINER_IMAGE`, `CONTAINER_PULL_POLICY`, `AVM_SSL_CERT_FILE`,
`NODE_EXTRA_CA_CERTS`, `CAROOT`, the `AVM_*_URL` overrides) are not
read by this module; mirror them through `.avm/config.json` and
`AVM_MIRROR` instead. Azure-auth env vars (`ARM_CLIENT_ID`,
`ARM_TENANT_ID`, etc.) flow through to subprocesses untouched and are
still required for any future integration-test or examples-deployment
workflow.

---

## 8. Legacy escape hatch

This module does **not** include a `--use-porch` or
`--use-container` fallback. If a repo needs `mapotf`, `grept`,
`avmfix`, or the porch-driven examples-deployment workflow today, keep
the legacy `./avm` shim and `mcr.microsoft.com/azterraform` container
alongside `avm pre-commit` / `avm pr-check` until the corresponding
follow-up slice lands. The two surfaces coexist cleanly — they read
different config files and write to different caches.

---

## 9. Troubleshooting

- **"Subprocess output looks like mojibake on Windows."** The module
  forces `[Console]::OutputEncoding` and `$OutputEncoding` to UTF-8 on
  import (Windows only) so subprocess stdout/stderr decode cleanly.
  If you've set this yourself before importing, set
  `$env:AVM_NO_CONSOLE_CONFIG = '1'` first. See
  [CONTRIBUTING.md § 9](../CONTRIBUTING.md#9-os-specific-notes).
- **"`avm check policy` reports `skipped`."** Either
  `avm-policy-aprl` or `avm-policy-avmsec` is missing from your
  effective config. Add both to `<repo-root>/.avm/config.json` per
  [§ 4](#4-pinned-asset-config), then re-run.
- **"`avm transform` always skips."** That's expected today —
  the engine is a stub pending the Phase 2 §2 decision. The composition
  verbs treat it as `skipped` so the rest of the chain still runs.
- **"PSSA `NullReferenceException` during `./build.ps1 lint`."**
  Known transient; the build wrapper retries automatically. Set
  `$env:AVM_LINT_MAX_ATTEMPTS` higher if needed. See
  [`docs/progress.md`](progress.md) § *Known issues*.

---

## See also

- [`docs/progress.md`](progress.md) — live checklist and known issues.
- [`docs/avm-implementation-spec.md`](avm-implementation-spec.md) —
  engineering rules (file layout, encoding, cross-OS, error handling,
  test layers).
- [`docs/avm-consolidation-plan.md`](avm-consolidation-plan.md) —
  scope and phase sequencing.
- [`docs/quality-standards.md`](quality-standards.md) — cross-cutting
  standards and traps (encoding, cross-OS, subprocess, PSScriptAnalyzer
  + Pester traps, networking, test layers, manifest casing, error
  handling, commit + push protocol).
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — dev loop, install path,
  publish process, OS-specific notes.
