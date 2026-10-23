# AVM Authoring Quality Specification

This is the single source of truth for the purpose, architecture, engineering
standards, and mandatory maintenance practices of the `Avm.Authoring`
PowerShell module and its `avm` command.

The module consolidates the authoring and CI tooling used by Azure Verified
Modules across Bicep and Terraform. It provides one cross-platform PowerShell
7 interface, local and CI parity, checksum-pinned managed tools, deterministic
output, and an incremental path away from repository-specific scripts and
containers.

Historical delivery plans and per-change progress records are intentionally not
kept in this repository. Git history, issues, and pull requests record completed
work. This document records only the current contract that future changes must
preserve.

## Product direction

The module follows these constraints:

- One stable `avm` command and approved-verb PowerShell cmdlets serve both
  Bicep and Terraform.
- Local commands and CI use the same implementation and validation paths.
- Existing module repositories can adopt the tooling incrementally.
- The module wraps proven tools rather than rewriting them without a concrete
  benefit.
- Managed tools are installed on demand from version- and checksum-pinned
  definitions; users do not need Docker, `make`, or `porch`.
- PowerShell remains the engine. A future native front end is justified only by
  a demonstrated requirement such as a rich terminal UI, material parser
  complexity, or host-startup cost.
- Security controls, deterministic behavior, and cross-platform support take
  priority over convenience.

---

## Security stance

Security is the **top non-functional priority** for this module, in line with the Microsoft Secure Future Initiative (SFI). Every other rule in this spec is subordinate to it; when a spec rule and a security control disagree, the security control wins, and any change that loosens a security control requires an SFI sign-off recorded in the PR.

The stance has three pillars:

- **Secure by design.** Every new public verb, network call, subprocess invocation, file write, and credential touch is threat-modelled at PR time (what data is handled, which identities are touched, which dependencies are added, what the blast radius is on compromise). New code that fails the threat-model pass is rejected — patches do not happen post-merge.
- **Secure by default.** Defaults never compromise the user. TLS 1.2 minimum (section 16). `GITHUB_TOKEN: contents: read` unless a write scope is justified job-by-job (section 17). No `-SkipCertificateCheck` (section 16). No plain-text secrets in parameter form (section 17). No `Invoke-Expression`, no `cmd /c`, no `bash -c` on user input (section 9). No PATH-resolved tool execution unless the caller explicitly opts in with `-AllowPathFallback` (section 10).
- **Secure operations.** Default managed downloads are pinned and integrity-verified. Workflow actions are pinned to commit SHA (section 17). Binary and runtime PowerShell packages are pinned by SHA256 in `Resources/avm.pins.jsonc` and verified on download (section 10). Build-time PowerShell dependencies retain their workflow constraints and release gate (section 20). The explicit repository version-override exception in section 10 requires SFI sign-off before merge/release. Dependabot keeps the action SHAs fresh; the lock-refresh script keeps the tool SHAs fresh — both rotations are PR-reviewed.

Default managed downloads must resist silent tag-repointing and version drift through pinned hashes. Explicit version overrides deliberately waive that fixed-hash guarantee only for the named tools; they must not change default verification, TLS, source-host restrictions, or offline controls.

---

## 1. Scope and audience

- **Audience**: contributors to this repository (`Azure/azure-verified-modules-tools`).
- **In scope**: code conventions, OS portability, public API shape, manifest rules, tool-cache layout, testing, release, security.
- **Delivery tracking**: roadmap items and completed work belong in issues and
  pull requests, not additional plan, decision-history, or progress documents.
- **Stability**: this spec is living and tracked in git. Breaking changes are PR-reviewed.

---

## 2. Supported platforms and runtimes

### Operating systems

| OS                                        | Architectures   | Status      |
| ----------------------------------------- | --------------- | ----------- |
| Windows 10 22H2 and later, Windows 11     | `x64`, `arm64`  | Tier 1      |
| Windows Server 2019, 2022, 2025           | `x64`           | Tier 1      |
| Ubuntu 22.04, 24.04                       | `x64`, `arm64`  | Tier 1      |
| Debian 12                                 | `x64`, `arm64`  | Tier 1      |
| Azure Linux 3                             | `x64`, `arm64`  | Tier 1      |
| macOS 13 and later                        | `arm64` (`x64` best-effort) | Tier 1 |
| RHEL 9, CentOS Stream 9, Rocky 9          | `x64`, `arm64`  | Tier 2      |
| Alpine 3.19+                              | `x64`, `arm64`  | Tier 2 (musl quirks accepted) |

- **Tier 1** means CI runs the full Pester matrix there and a failing test blocks release.
- **Tier 2** means CI runs smoke tests only; bugs are accepted as issues but do not block release.

### PowerShell

- **Minimum**: PowerShell 7.4 (current LTS).
- **Not supported**: Windows PowerShell 5.1, PowerShell 6.x, PowerShell 7.0–7.3.
- The manifest declares `PowerShellVersion = '7.4'` and `CompatiblePSEditions = @('Core')`.

### Other host tooling the user must supply

| Tool       | Purpose                                  | Min version |
| ---------- | ---------------------------------------- | ----------- |
| `git`      | Module discovery, governance scripts     | 2.40+       |
| `gh`       | Optional — required only for `avm governance` | 2.40+   |
| `az`       | Optional — required for `avm register-features` and Azure-backed test tiers | 2.60+ |
| .NET SDK   | Optional — required only by future native-host experiments | 9.0+ |

Everything else (Terraform, TFLint, `terraform-docs`, Conftest, `avmfix`, `mapotf`, `grept`, Bicep) is installed and managed by the CLI per §10.

---

## 3. Cross-OS guarantees

Every public verb produces **byte-identical exit codes**, **structurally identical JSON output** (under `--json`), and **semantically identical filesystem effects** across every Tier 1 platform listed above. CI validates affected scopes using the Windows, Linux and macOS matrix in section 18. A failing selected platform check is a release blocker.

Human-readable text output is allowed to differ in formatting (line endings, ANSI colour) per §11.

---

## 4. Repository layout

```text
azure-verified-modules-tools/
  src/
    Avm.Authoring/
      Avm.Authoring.psd1          # manifest — id casing locked
      Avm.Authoring.psm1          # entry point; dot-sources Public/Private
      Public/                     # exported cmdlets, one file per cmdlet
      Private/                    # internal helpers, one file per function
      Engines/
        Bicep/                    # facade over utilities/tools PS scripts
        Terraform/                # facade over avmfix/mapotf/grept/terraform
      Resources/
        avm.pins.jsonc           # pinned tool versions + SHA256
        PSScriptAnalyzerSettings.psd1
      en-US/                      # Import-LocalizedData strings
      README.md
  build/
    avm.build.ps1                 # Invoke-Build task graph
    tasks/                        # per-area task scripts
  tests/
    Pester/
      Unit/                       # no FS, no network
      Component/                  # real FS, stub binaries, no network
      Integration/                # network-dependent + real binaries, gated by -Tag Integration
    fixtures/                     # static test inputs
  scripts/
    Install-AvmBuildPrerequisites.ps1
    Update-AvmPins.ps1
    Publish-AvmAuthoring.ps1      # validates and publishes ADO-signed release assets
  docs/
    quality-spec.md               # this file
    reference/                    # generated public cmdlet reference
  .github/
    workflows/
      ci-authoring.yml
      ci-workflows.yml
      repository-management-config-test.yml
  .gitattributes
  .gitignore
  LICENSE                         # MIT, referenced by manifest LicenseUri
  README.md
```

Rules:

- One cmdlet per file in `Public/` and `Private/`; file basename matches the function name exactly (case-sensitive).
- `Avm.Authoring.psm1` discovers `Public/*.ps1` and `Private/*.ps1` via `Get-ChildItem`, dot-sources them, and exports only the public set explicitly via `Export-ModuleMember -Function …`.
- Tests mirror the source tree: `Public/Invoke-AvmPreCommit.ps1` ↔ `tests/Pester/Unit/Public/Invoke-AvmPreCommit.Tests.ps1`.

### Module context contract

- PWD, or explicit `-Path`, is the authoritative module root. Context
  resolution never walks parent directories.
- A same-root `.avm/context.psd1` override has highest precedence. An explicit
  ecosystem that conflicts with the override is an error.
- Without an override, direct `*.tf` source selects Terraform and direct
  `*.bicep` source selects Bicep. `terraform.tf` distinguishes
  `terraform-module-repo` from `terraform-module-path`; convention folders and
  version files do not participate in detection.
- A root containing `bicepconfig.json` and at least one
  `avm/{res,ptn,utl}/` folder is a `bicep-monorepo`. This exception is required
  because a supported Bicep monorepo root has no direct module source.
- Automatic resolution throws when both ecosystems match. Explicit
  `-Ecosystem` succeeds only when matching source exists.
- Before override or source detection, scan every directory segment from the
  authoritative path through the filesystem root. Reject the path if any
  segment is `tests`, `examples`, `modules`, `.agents`, `.avm`, `.git`,
  `.github`, `.terraform`, or `.vscode`. This is only a rejection guard; it
  must never return an ancestor as context. It deliberately can false-positive
  when a higher checkout path happens to use a reserved name.

### Terraform lint scopes

TFLint evaluates the repository root and each direct `modules/*` and
`examples/*` directory separately. The root configuration leaves
`avm_terraform_module_source_required` in its default root scope; the submodule
configuration explicitly sets `module_scope = "submodule"`. Root local sources
must use `./modules/<name>`, and submodules may use `../<name>` for a direct
sibling. Traversal and nested local module roots remain invalid. Examples
retain their existing source-rule exemption. Shared and per-scope overrides
merge attributes without dropping this scope context.

---

## 5. PowerShell coding standards

### Required at the top of every public function

```powershell
function Invoke-AvmPreCommit {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $Module = $PWD.Path
    )
    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }
    process {
        # …
    }
}
```

### Naming

- All exported functions use approved verbs (`Get-Verb`). Build fails if PSScriptAnalyzer's `PSUseApprovedVerbs` flags any.
- Function nouns use `Avm` prefix: `Invoke-AvmPreCommit`, `Get-AvmModuleContext`, `Install-AvmTool`.
- Private helpers can use any verb but follow the same `Avm` prefix.
- Parameters are PascalCase, no abbreviations (`-Module`, not `-Mod`).

### Style

- 4-space indent, no tabs.
- One statement per line.
- Always brace single-line `if`/`foreach`.
- No aliases (`Get-ChildItem`, not `gci`). Enforced by PSScriptAnalyzer `PSAvoidUsingCmdletAliases`.
- No positional cmdlet calls in module code. Tests and one-off scripts may use them.

### File encoding and line endings

- All `.ps1`, `.psm1`, `.psd1`, and `.md` files: **UTF-8 without BOM**.
- Line endings: **LF** in the repo. `.gitattributes` enforces this:

  ```gitattributes
  * text=auto eol=lf
  *.ps1 text eol=lf working-tree-encoding=UTF-8
  *.psm1 text eol=lf working-tree-encoding=UTF-8
  *.psd1 text eol=lf working-tree-encoding=UTF-8
  ```

- A pre-commit Pester test fails if any file in `src/` contains a BOM or a `CRLF`.

---

## 6. OS-agnostic path and filesystem rules

### Never assume

- Path separator. **Always** use `Join-Path` or `[System.IO.Path]::Combine(...)`. Never literal `/` or `\`.
- PATH separator. **Always** use `[System.IO.Path]::PathSeparator` (`;` on Windows, `:` elsewhere).
- Line ending. Use `[System.Environment]::NewLine` when writing files the user will edit; use `"`n"` when writing files only the CLI reads.
- Case-insensitivity. **Always** assume the filesystem is case-sensitive, even on Windows / NTFS. See §6.2.

### Path helpers (mandatory)

| Concern             | Use this                                                  | Never use                            |
| ------------------- | --------------------------------------------------------- | ------------------------------------ |
| Join two segments   | `Join-Path $a $b`                                          | `"$a/$b"`, `"$a\$b"`                  |
| Join many segments  | `[System.IO.Path]::Combine($a, $b, $c)`                    | nested `Join-Path` (works but noisy) |
| Home dir            | `$HOME`                                                   | `$env:USERPROFILE`, `$env:HOME`      |
| Temp dir            | `[System.IO.Path]::GetTempPath()`                          | `$env:TEMP`, `/tmp`                  |
| Current OS check    | `$IsWindows`, `$IsLinux`, `$IsMacOS` (built-in in PS 7)    | string-match on `[Environment]::OSVersion` |
| Architecture check  | `[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture` | parsing `uname` output |
| Executable suffix   | `if ($IsWindows) { '.exe' } else { '' }`                  | hardcoding `.exe` anywhere           |
| Path separator      | `[System.IO.Path]::PathSeparator`                          | hardcoding `;` or `:`                |
| Directory separator | `[System.IO.Path]::DirectorySeparatorChar`                 | hardcoding `\` or `/`                |

### Case sensitivity

The 2026-05 publishing incident is the canonical lesson: NTFS preserves casing across delete-and-recreate; `Publish-PSResource` derives the .nuspec `<id>` from on-disk file casing, not from `Test-ModuleManifest` `Name`. Treat every filesystem as case-sensitive.

- String equality on filesystem names uses `-ceq` / `-cne` or `[string]::Equals($a, $b, [System.StringComparison]::Ordinal)`.
- Pattern matches on filesystem names use `-cmatch` / `-clike`.
- Test fixtures include a case-collision file (e.g. `Foo.txt` and `foo.txt` in the same directory) that runs on Linux only and validates the resolver doesn't silently pick the wrong one.
- Never call `Test-Path` to verify a specific casing — `Test-Path` is case-insensitive on NTFS and APFS. Use `Get-ChildItem | Where-Object { $_.Name -ceq $expected }` instead.

### Path length

- Keep all generated paths well below 260 characters even when Windows long-path support is enabled.
- Use short hashes (first 12 hex of SHA256) where a content-addressed segment is needed, not full hashes.
- Tool cache uses `<DataDir>/tools/<tool>/<version>/<binary>` — no per-invocation subdirs.

### Symlinks and reparse points

- The module **does not create** symlinks. If a future verb needs them, the change goes through this spec first.
- The module **may follow** symlinks the user has set up; resolved paths are obtained via `(Get-Item $path).Target` then `Resolve-Path`.

### Permissions and the executable bit

- After extracting a downloaded binary on non-Windows, set the executable bit:

  ```powershell
  if (-not $IsWindows) {
      & chmod +x $binaryPath
      if ($LASTEXITCODE -ne 0) { throw "chmod +x failed for $binaryPath" }
  }
  ```

- On Windows, the `.exe` suffix is sufficient and required for Windows to treat the file as executable.

---

## 7. Standard user folder locations

The module never writes inside the repository or inside its own install location. All persistent state lives under per-user directories chosen by `Get-AvmFolder` in `Private/`. This is the **only** place that decides where state goes.

### Default layout

| Purpose                         | Windows                                  | Linux (XDG-friendly)                                              | macOS                                                 |
| ------------------------------- | ---------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------- |
| Config (`config.json`, prefs)   | `%APPDATA%\Avm`                          | `${XDG_CONFIG_HOME:-$HOME/.config}/avm`                            | `$HOME/Library/Application Support/Avm`                |
| Cache (governance assets, etc.) | `%LOCALAPPDATA%\Avm\Cache`               | `${XDG_CACHE_HOME:-$HOME/.cache}/avm`                              | `$HOME/Library/Caches/Avm`                             |
| Data (tool binaries)            | `%LOCALAPPDATA%\Avm\Tools`               | `${XDG_DATA_HOME:-$HOME/.local/share}/avm/tools`                   | `$HOME/Library/Application Support/Avm/Tools`          |
| State (logs, metrics)           | `%LOCALAPPDATA%\Avm\Logs`                | `${XDG_STATE_HOME:-$HOME/.local/state}/avm/logs`                   | `$HOME/Library/Logs/Avm`                               |
| Temp (scratch, atomic stage)    | `[System.IO.Path]::GetTempPath()`        | `[System.IO.Path]::GetTempPath()`                                  | `[System.IO.Path]::GetTempPath()`                      |

Linux follows the [XDG Base Directory Spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html) and honours the override environment variables. macOS follows Apple's [File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html). Windows follows the [Known Folders](https://learn.microsoft.com/windows/win32/shell/knownfolderid) convention.

### The `AVM_HOME` override

A single environment variable overrides every default:

```text
$env:AVM_HOME = '/custom/path/avm'
  → config : $env:AVM_HOME/config
  → cache  : $env:AVM_HOME/cache
  → tools  : $env:AVM_HOME/tools
  → logs   : $env:AVM_HOME/logs
```

This is the integration point for `mise` / `asdf` / `tenv` users who centralise tool installs, for ephemeral CI workers that want everything in `$RUNNER_TEMP/avm`, and for self-contained portable installs.

### Resolver contract

`Get-AvmFolder -Kind <Config|Cache|Data|State|Tools|Logs>`:

- Returns an absolute, normalised path with **forward slashes converted to the platform separator** via `Resolve-Path`.
- Creates the directory if it does not exist, with permissions `0700` on Unix (user-only).
- Honours `AVM_HOME` first, then OS defaults.
- Is pure with respect to env vars — same env in, same path out — and has unit tests on all three OSes.

---

## 8. Hidden folder and repo-local conventions

### Terraform Azure authentication

Terraform policy, integration and e2e share one Azure authentication preflight.
Run it after the applicable pre/setup hook and `.env` loading, before Terraform
init, plan, test or apply. Per-example/target overrides take precedence over the
process environment. Non-CLI authentication requires `ARM_SUBSCRIPTION_ID` and
the identity inputs for the selected secret, certificate, OIDC, managed-identity
or AKS workload-identity method; incomplete inputs fail without CLI fallback.
Otherwise inspect the existing Azure CLI account through the shared CLI resolver
and process helper, requiring an enabled subscription and tenant matching any
explicit IDs. Supply those IDs only to child processes so providers cannot plan
with an empty subscription; never sign in, switch accounts or mutate the caller's
environment. Diagnostics name missing inputs and recovery commands, not values
or raw CLI output. Providers remain responsible for token validity and resource
permissions. Unit tests, discovery/listing and absent/ignored tiers need no
authentication. Preflight failures retain ordinary post-hook cleanup behavior.

### Terraform policy recovery staging

Terraform policy checks stage examples under `Get-AvmFolder -Kind Cache` in
`policy-stage/avm-policy-<unique-id>`. Immediately before its pre hook, each
example marks cleanup required and confirms it only after its post hook returns
successfully. Examples that never start hooks do not require fixture cleanup.
The parent checks every example after workers finish; failed, interrupted, or
unconfirmed cleanup retains the entire staging tree in place, preserving local
state, Terraform data, plans, hooks, and environment files without relocation.
Successful post cleanup still removes staging even after a primary check error.
Retention is not a successful check or permission to retry cleanup automatically.

Retained staging inherits the standard user-cache protection and is never
uploaded as a public artifact. Diagnostics report the recovery path and error
types, not state, plans, environment values, or secondary hook-error contents.
Keep the original typed terminating error; attach a simultaneous post ErrorRecord
in `Exception.Data['AvmPolicyPostError']` and the retained path in
`Exception.Data['AvmPolicyStagePath']`. A staging-removal failure must also remain
explicit, preserving a prior error and attaching its secondary ErrorRecord in
`Exception.Data['AvmPolicyStageCleanupError']`. Recovery and manual deletion
require operator action; checks do not inspect or operate on retained state.

### Per-repo files

The CLI does not require any per-repo state. Persistent state (tool cache,
resolved governance assets, logs) lives under `$AVM_HOME` / the per-OS
folders described in §7, never inside the user's module repo.

A repo may *optionally* carry a `.avm/` folder holding per-repo overrides and
the managed-files pin. Everything except the pin is hand-authored, and the CLI
only ever reads it:

```text
<repo>/
  .avm/
    config.json                  # per-repo pinned-asset / policy overrides
    tool-version-overrides.json  # known-tool version overrides (read-only)
    managed-files.json           # per-repo managed-files sync-source override
    managed-files-version.json   # managed-files release pin (CLI-managed)
    context.psd1                 # per-repo context override
    .disable                     # zero-byte sentinel — CLI refuses to run if present
```

Module roots may separately contain `.required-features.json`, a hand-authored
JSON array of `"Namespace/FeatureName"` strings. Bicep registry modules
(`.../avm/res|ptn|utl/...`) instead use the repository-root
`.required-features.json`, an object keyed by exact module paths such as
`avm/res/compute/virtual-machine`; the whole object is validated and a
module-root manifest is rejected. `avm register-features`
reads this file only; an absent or empty array does nothing. The command
requires an explicit subscription GUID, validates every entry before calling
Azure CLI, verifies that the CLI is selected to that subscription, and never
unregisters a feature. The protected Terraform integration and e2e jobs run it
only when the manifest is nonempty. Bicep `avm test e2e` reads the manifest
before confirmation and registers the features once per selected subscription.

Bicep registry modules may also declare `.required-resource-providers.json`
at the repository root. It maps exact lowercase `avm/res|ptn|utl/...` module
paths to arrays of provider namespaces. This selection is independent of
identity-root selection: never inherit a parent's requirements for a child,
read a nested provider manifest, or accept an underscore filename alternative.
Validate the whole map, including unselected entries, before dependencies or
Azure calls. Reject duplicate keys/namespaces, malformed JSON, non-string
entries, unsafe namespace syntax, files over 64 KiB, more than 32 requirements
per module and namespace parts over 128 characters. Missing, empty and unrelated
maps are logged registration no-ops; WhatIf validates without Azure calls.

One private parser and registration implementation serves features and providers.
Resolve declarations for each selected case's exact owning module before effects,
including recursive and child-example selection; never inherit the invocation
parent's declarations. Cache completed registrations by subscription and exact
requirement, so one case cannot suppress another owner's distinct prerequisites.
After compilation and identity verification, Bicep All/Deploy completes feature
registration and its provider refresh, then required provider registration,
before template/parameter token replacement, validation or deployment.
Registered providers are left alone; Registering providers are polled without
resubmission; NotRegistered/Unregistered providers register once and are polled.
Recheck the selected subscription, tenant, cloud and principal before each
registration command/read, and bind every response to the requested identity.
Approval, unknown states, native errors, timeouts and cancellation fail explicitly;
registration failure cannot continue to tokens or deployment. Complete and
cleanup do not read these manifests or register prerequisites. Registrations
persist; never unregister, grant roles, accept service terms or switch the
authenticated account. Terraform's feature-only API and automatic-provider-
registration safeguards are unchanged.

Rules:

- `managed-files-version.json` is the sole file in `.avm/` the CLI writes; see
  the version-pin section below. Every other file is read-only to the CLI,
  which never creates it. If none exist, the CLI runs entirely from packaged
  defaults and `$AVM_HOME`.
- The CLI never adds `.avm/` (or anything else) to the repo's `.gitignore`.
  Whether the override files are tracked in git is the user's choice, but the
  version pin must be committed, so the managed-files repository removes the
  historical `.avm` entry from the managed `.gitignore`.
- The leading dot is a Unix convention. Windows Explorer does not treat dotfiles as hidden, and we **do not** set `FILE_ATTRIBUTE_HIDDEN` via `attrib +h` — too surprising and not worth the friction.
- The CLI never creates other dotfiles or dot-folders in user repos (no `.avm-cache`, no `.avmrc`, etc.). One folder, one namespace.
- A `.avm/.disable` sentinel makes the CLI exit `2` with a clear message: `"avm is disabled in this repository (remove .avm/.disable to re-enable)"`. This gives a clean opt-out for repos that don't want the CLI to ever touch them, even by accident.

### Managed-file version pin

`.avm/managed-files-version.json` records which release of the managed-files
repository a module repo is synced against. It is written by `avm pre-commit`
and read by every managed-file operation:

```json
{
  "version": "1.0.0",
  "repo": "Azure/azure-verified-modules-managed-files",
  "commit": "3f949ae3da0ead8bdb85d405659c9991a976b231",
  "commitDate": "2026-08-11T21:52:43Z",
  "updatedAt": "2026-08-12T11:08:52Z"
}
```

`version` is a semver string with no leading `v`; the corresponding git tag is
`v$version`. `commitDate` is the committer date of the tagged commit and
`updatedAt` is when the CLI last wrote the file. Both are rendered as
`yyyy-MM-ddTHH:mm:ssZ`. The file is UTF-8 without BOM, LF-terminated, with a
trailing newline, per §5.

The sync ref is resolved by this precedence, highest first:

1. An explicit `-ManagedFilesRef` argument.
2. `AVM_MANAGED_FILES_REF`.
3. `ref` in `.avm/managed-files.json`.
4. `v$version` from `.avm/managed-files-version.json`.
5. `main`.

Tiers 1–3 are deliberate operator overrides and disable version enforcement
entirely — no warning, no error, and no write to the pin. Only tier 4 or the
unpinned fallback participate in the checks below.

Enforcement, given the newest published release:

- **Equal** — sync at the pin, say nothing.
- **Newer patch or minor** — sync at the pin and warn.
- **Newer major** — throw `AvmManagedFilesVersionException` (`AVM1060`). The
  operator must rerun with `-Upgrade`.
- **No pin** — adopt the newest release and stamp it silently. This is how the
  file first appears in a repo.
- **Lookup failed** — warn and continue against the pin. Managed-file sync must
  not depend on network reachability.

`-Upgrade` always moves to the newest release and rewrites the pin. Drift
checks (`avm pr-check`) never write the pin, because they run against a clean
working tree that they must leave clean; a superseded major surfaces there as a
drift finding rather than a rewrite.

### Managed-file cache recovery

If fetching or checking out a cached managed-files or configuration repository
exits with code 128 and Git's `fatal: not a git repository` diagnostic, warn,
remove only the affected repository/ref cache entry, and retry with one shallow
clone at the same ref. Preserve unrelated Git failures and propagate a failed
replacement clone; existing transient-network retries remain unchanged.

### Managed-file source layout

Managed-file sources stack `<base>/root/` followed by configured overlay
directories. A subtree below any named `<parent>/_all/` path is broadcast into
every existing immediate child of the corresponding target parent, preserving
the remainder of the source path. Reserved `_all` segments are expanded from
left to right, so they can be chained for explicitly nested broadcast scopes.
They are never copied literally and do not create missing target parents or
child directories. A root-level `_all/` has no named parent and remains a
literal managed path.

Each source layer applies broadcast templates before concrete paths, so an
explicit path in that layer is more specific. Later overlays still win over
earlier layers, and exclusions are evaluated against the expanded target paths.

### Module-owned metadata

Root and child Bicep/Terraform modules may adopt a strict `metadata.json` beside
their source. The authoritative v1 input and catalog schemas are packaged under
`Resources/Schemas/v1/` in this repository; validators never fetch a module's
`$schema` URL at runtime. The required versioned `$schema` reference identifies
the authored format; module metadata does not also store `schemaVersion`.
Resource `canonicalType` values remain full, case-sensitive ARM resource types
under `Microsoft.*` or the exact `Oracle.Database` namespace. Resource segments
cannot contain another dotted namespace; synthetic family-qualified types such
as `Microsoft.Storage/storageAccounts/Microsoft.Insights/diagnosticSettings`
are invalid. Pattern and utility values may be single taxonomy names such as
`naming`, or slash-separated paths such as `lz/sub-vending`, for both root and
reduced child metadata.
Exact lowercase `helper` is reserved for child/submodule metadata in either
ecosystem and any resource, pattern, or utility family. It is not an ARM type
or a new authored module kind; roots cannot use it.
This does not change repository naming or grouped Bicep module-path conventions.
Root metadata owns a flat `owners` string array: bare GitHub usernames and
qualified `@organization/team-slug` handles. Empty arrays are permitted and
case-insensitive duplicates are rejected. Tier is not part of this contract.
Children carry only their own identity, description, optional telemetry prefix,
and optional array of previous telemetry prefixes; catalog generation inherits
ownership from the family root.
Generated catalog records enrich each inherited handle into a strict
`{ handle, type, displayName }` object. `type` distinguishes GitHub users from
teams; user display names are profile names and team display names are team
descriptions. Missing profile display data is represented as null.
Helpers may omit telemetry even when published or instrumented. Supplied helper
prefixes are preserved and retain ecosystem, family-kind, format, and length
validation. Non-helper resource/pattern roots and directly published children
require telemetry.
Uninstrumented Bicep children without a version file may omit the prefix under
BCPFR4, as may telemetry-free utilities. Bicep prefixes are limited to 50
characters. Terraform prefixes have the fixed 20-character form
`46d3xtrf.<res|ptn|utl>.<seven lowercase hexadecimal characters>`.
The generated Terraform name reserves space for the version, source token,
and instance suffix within ARM's 64-character limit.
The optional `alternativeTelemetryIdPrefixes` array retains previous identifiers
for a module when its primary prefix changes. Historical Terraform identifiers
may use descriptive segments and remain limited to 59 characters; the 20-character
current-prefix requirement does not retroactively apply to those alternatives.
Entries must be distinct from the current prefix and match its ecosystem and
module kind; Bicep alternatives remain limited to 50 characters. The exact
historical Resource Graph identifier remains valid only for Resource Graph.
Generated catalog JSON always includes the array, empty when absent from
metadata, without changing the v1 schema references or schema version.
New Bicep and Terraform prefixes end in seven lowercase hexadecimal characters;
existing underscore identifiers remain valid as historical values. Metadata
initialization does not repair deployed telemetry.
Empty owner lists are allowed. Deprecated, unpublished modules are excluded from
generated CSV indexes and catalog JSON after full validation; published deprecated
modules remain Deprecated. Otherwise, unpublished modules are Proposed regardless
of owners or source files; published modules without owners are Orphaned, and
published modules with owners are Available. Existing Deprecated state is retained
as a deprecation signal during transition. A multi-scope Bicep root counts as
published for lifecycle status and deprecation retention when any direct
`rg-scope`, `sub-scope`, or `mg-scope` module is published. Its registry fields
still describe the root path, without an invented release version or date;
ordinary children do not promote their parents.
New deprecations are derived from Bicep `DEPRECATED.md` (covering that
module and descendants), or
the Terraform repository's archived flag (covering all its modules). There is
no authored metadata status field. Each excluded module produces a warning naming
its repository/module path and recommending deletion of unused source, without
deleting anything or removing published descendants. The approved MAR
registration mirror remains unchanged.

`avm metadata validate` requires the caller's ecosystem, module kind, and child
scope. `-CheckSource` also verifies the required Bicep literal name and
description declarations and source telemetry requirements when main.bicep
exists. Bicep `metadata name` and `metadata description` serve different
purposes from JSON `moduleDisplayName` and `moduleDescription`; neither pair
must match. A metadata-only Bicep scope may omit main.bicep only when it has
neither version.json nor main.json at that scope. Source markers without
metadata are also discovered and rejected. The catalog separately rejects
source-less modules reported as published by the registry.
`-InputObject` validates supplied metadata values without reading a file.
`avm metadata show` only reads and validates an existing `metadata.json`; it
never derives values or reads CSV indexes.
`avm init` is the one-time entry point. Callers supply
`-Ecosystem`, `-ModuleType`, and `-Path`; `-Proposed` is Bicep-only and creates
only `metadata.json`, even when the module and provider directories do not
exist yet. Full Bicep
initialization scaffolds the root's metadata.json, main.bicep, version.json,
CHANGELOG.md, and defaults/WAF-aligned tests/e2e sources; children receive
only metadata.json and main.bicep. Bicep initialization creates neither
main.json, README.md, a remote repository, nor a deployment. Existing files
remain unmodified.
Terraform root initialization creates and sets up the `Azure/<repository>`
GitHub repository named by `-Path`, as a sequence of resumable stages that
each query the current local and GitHub state first: write metadata.json to
the folder, create the public repository, wait for open source portal setup
and JIT elevation, grant the module contributors (push) and readers (triage)
teams, publish the first commit to `main`, request the AVM app installations
in `microsoft/github-operations` unless the repository is listed there or an
open request exists, and clone the repository into an empty folder. The first
commit is built in a temporary clone from the portal's seed files,
metadata.json, the packaged minimal scaffold (`Resources/Scaffolds/Terraform`),
and `avm pre-commit` output. The scaffold is an AzAPI virtual network that takes
`parent_id` and exposes the AzAPI `resource_types`, `retry`, `timeouts` and
`ignore_body_changes` interfaces; its default example picks a recommended
region through `Azure/avm-utl-regions/azurerm` and names resources through
`Azure/avm-utl-naming/azure`. No other local content is published. Interrupted
or non-interactive runs stop with instructions and resume on the next run.
Terraform `-ChildModule` initialization creates only local metadata.json.
After source exists, `avm pre-commit` compiles each root and child
`main.bicep` into `main.json` through the pinned Bicep CLI. It leaves
unchanged output bytes and timestamps alone. A proposed module with only
metadata.json needs no compiled artifact.
The direct
`avm metadata initialize` command remains available for scripted callers;
it does not create a missing Terraform directory unless explicitly requested.

For full Bicep `-ChildModule` initialization, `-Path` is the target in
`avm/{res,ptn,utl}/<group>/<module>[/child...]`. The command validates and
creates every missing root and intermediate child through that target in a
single transaction, using root-only extras at the root. `-InputObject`
provides target metadata. `-AncestorInputObject` optionally maps exact
lowercase root-relative paths to metadata dictionaries for missing ancestors:
`.` for the root, then `child`, `child/grandchild`, and so on, excluding
the target itself. Lookup compares actual supplied keys with these canonical
paths ordinally rather than relying on a PowerShell hashtable's
case-insensitive indexing. Unknown, wrongly cased, escaping, and non-dictionary
entries are errors. Existing ancestors' metadata inputs are ignored and
their files are preserved. Interactive calls prompt for absent fields at
each missing ancestor; noninteractive calls fail with the ancestor path and
missing field names. `-Proposed` never cascades and does not accept an
ancestor map. For new uninstrumented children without a version file,
telemetry remains optional. New utility roots without telemetry use
telemetry-free source. Source-authored literal prefixes are preserved when
metadata is missing, without rewriting the source; conflicts fail. New Bicep
scaffolds seed their source literals from JSON metadata, but existing source
names and descriptions are preserved and validated independently.
Validate metadata, exact path casing, source literals, templates, target
files, and the whole root-to-child plan before confirmation or any write.
`-WhatIf` validates and reports the same planned files without writing;
writer failures roll back files and directories it created.

For new metadata, initialization supplies the bundled `$schema` URI and, when
required, generates a Bicep telemetry prefix against current and historical
identifiers in the published catalog and local monorepo metadata. A catalog
lookup failure warns and still checks local identifiers; invalid local
metadata fails instead of being skipped. Already supplied values remain
unchanged and are validated before prompting for missing required fields.
Interactive terminals prompt for missing identity, description, canonical
type, and root owners (including an empty owner list); noninteractive runs
fail with the missing field names. An existing metadata file is validated and
preserved without prompting or a catalog lookup. `-WhatIf` plans without
creating directories or files.

`avm metadata initialize` never overwrites existing files. `-UpdateSource`
adds a scoped Bicep telemetry load without replacing telemetry transport.
New source wiring and telemetry-enabled root scaffolds use
`var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')`
and `${telemetryIdPrefix}` in the deployment name. Existing source using that
form or the earlier `avmTelemetryIdPrefix`/`$.telemetryIdPrefix` form is
preserved without migration; conflicting variable definitions fail.
When source wiring is requested and no prefix is supplied, initialization
retains the single, valid prefix already authored in main.bicep, excluding
that module's own published catalog record from duplicate checks. A prefix
used by another local or published module, or an explicit value conflicting
with the authored prefix, fails before either file changes.
Terraform rejects `-UpdateSource` before writes; initialization never
generates `main.metadata.tf` or removes existing authored source. Terraform
telemetry wiring is generated by MaPoTF.
The one-time source rewrite can change compiled Bicep output; subsequent
owner/canonical metadata edits do not.

MaPoTF instruments Terraform roots and children with a `telemetryIdPrefix`.
Children without a prefix do not create telemetry, but those deploying Azure
resources still require `var.location`. Every module root except a utility
that deploys no Azure resources requires `var.location`; MaPoTF adds a required,
non-nullable string input without a default when it is absent and preserves
authored declarations. Instrumented modules also get `enable_telemetry`
(default `true`). The deployment uses `var.location`, including in globally
scoped modules. Choose a valid region for the target cloud. Local module
calls forward the parent's location when the child needs it and no location
was authored, preserving
per-item locations in multi-region modules. Instrumented children also
receive `enable_telemetry = var.enable_telemetry` explicitly, overriding authored
child-call values as well as the child's default. Forward this input whenever
a local child exposes it, independently of whether the child requires location.
Helpers without that input remain unchanged. Supported example calls expose and forward
missing inputs. Only newly generated example `location` inputs default to
`"eastus"`, so runnable examples remain usable by noninteractive plans.
Authored example declarations, defaults, required inputs, and per-item regions
are preserved; reusable module inputs still receive no default. Override the
example value when another region or cloud is required.
Variable blocks are sorted after missing location inputs are
created, so the first transform already satisfies drift checks.

Before telemetry transformation, the `utility-module` profile migrates authored
registry calls by source, not by module label. Older exact pins of
`Azure/avm-utl-regions/azurerm` move to `0.13.0`; older exact pins of
`Azure/avm-utl-interfaces/azure` move to `0.9.0`. Equivalent
`registry.terraform.io/` addresses are supported. Current pins are preserved;
newer calls are left alone. Missing pins, ranges, prereleases and computed
versions on these sources require review, not a guessed version. Custom
registries, Git sources and local modules are not rewritten as registry calls.
Root, child, example and discovered test-wrapper scopes share this phase.
The MaPoTF profile owns source recognition, exact-pin selection, version
rewrites and required utility inputs. PowerShell only schedules scopes,
surfaces the profile's review result before any writes, and obtains necessary
external dependency facts; it must not reconstruct utility HCL fragments or
reimplement source/version selection.
These are fixed one-off migration targets, not latest-release lookups or an
automatic progression to future utility versions.

`AVM_TF_UTILITY_MIGRATION=preserve` is the supported opt-in for retaining
authored utility dependencies without accepting those migrations. Set it
consistently for `avm pre-commit`, `avm transform` and `avm pr-check`, including
CI. Unset, empty or `migrate` retains the default behavior; other values fail
configuration before the transform resolves tools or changes source.
Preservation still inspects recognized utility calls and requires literal exact
pins. It leaves their source, version, caller inputs and migration-related
provider bindings unchanged, rather than replacing the Mapotf profiles or
excluding transform. All other instrumentation, provider/mock reconciliation,
drift checks, lint and ordinary policy evaluation remain enabled. This is not
an approval to upgrade dependencies, freeze unrelated generated content or
weaken consumer checks. Existing lock selections remain protected by the same
initialization and native-inspection controls. In particular, preservation
does not waive a module-root lint rejection of legacy Naming; its retained
calls must already satisfy the applicable source rules.

Legacy `Azure/naming/azurerm` calls become `Azure/avm-utl-naming/azure` at
`0.2.0` in modern mode. Omit `legacy_mode` to use its false default; if an
old-source call already contains that input, set it to false. Preserve labels
and compatible authored inputs, including deprecated hyphenated inputs.
The pinned utility exposes deprecated named outputs as aliases of its modern
catalog results, so those references remain valid without rewriting callers.
Generated names and random seeds may change and consumer resources may be
replaced; review the Terraform plan. Do not delete state. Existing
`Azure/avm-utl-naming/azure` calls remain outside this conversion, preserving
all owner-selected versions and modes. This dependency requires Terraform
`>= 1.9, < 2.0` and Random `>= 3.3.2, < 4.0`. This phase does not rewrite
authored Terraform version constraints; Terraform enforces the dependency's
minimum versions, and existing provider-governance rules still apply.

Regions and Interfaces now require `location` and AzAPI `~> 2.12`; Interfaces
also retains Random for role assignments. Supply a missing utility location
from an independent `var.location`, never from that same utility's outputs.
New reusable inputs remain required; only new example inputs default to
`eastus`. Preserve authored locations and opt-outs, including existing utility
example telemetry defaults. Test wrappers receive no new telemetry control.
Callers that use AzAPI only through child modules rely on implicit default
provider inheritance; do not introduce a parent requirement or provider map
solely for that transitive dependency. When an existing explicit map must be
retained, add the newly required AzAPI binding and its parent source declaration
if absent, without replacing existing bindings or constraints. Removing the last
obsolete ModTM binding removes the map rather than replacing it with a default
AzAPI-only map. Terraform's built-in provider needs no generated
`required_providers` declaration.

The final `provider-inheritance` native profile removes a module call's entire nonempty `providers`
map only when every entry forwards an unaliased default to the identical local
name. This applies to every provider, including ModTM, AzAPI, AzureRM and
Random, regardless of whether the child genuinely uses it. Preserve maps with
any alias selection, aliased target key or different local-name binding in
full, including their necessary identity entries and comments. Native object
inspection determines these edits; PowerShell supplies only dependency facts.
Native test `run` provider maps and mock declarations are not module-call maps
and remain subject to the separate test-binding coverage rules.
Run this profile separately after restoration and ordering across every module,
example and test-wrapper scope. Planning removal and reordering together can
restore attributes from the ordering transform's original block snapshot.
Provider retirement in root and example/test-wrapper profiles must honor the
existing conservative provider-configuration and alias facts as well as direct
usage, so removing an identity map cannot retire an authored configuration's
source or version on a subsequent pass.
Include callers with existing provider requirements in native dependency
inspection even when utility selections are preserved or need no migration.
Run these scopes in provider-only mode when no utility upgrade is selected;
preserving utility selections must not skip the evidence needed to retain
their original provider source and version after final map removal.
After map removal, run a separate native `provider-contract` pass to retire
ordinary transitive-only declarations without lint exceptions. Preserve direct
resource/data/ephemeral uses, authored configurations, configuration aliases,
surviving explicit caller and mock bindings, and original source/version
constraints proven to constrain a current dependency. Version protection
requires the original and current source/version contracts to match; a newly
generated constraint does not establish an authored contract. Retire a
declaration only when pinned TFLint's native parser also reports it unused.
This protects authored provider configurations without extending the existing
PowerShell configuration-fact recognizer or adding a text parser. All
declaration-edit and retention decisions remain in MaPoTF.
When an owned unused-provider directive exists, inspect the scope in a
temporary module-tree copy with only that exact directive blanked, preserving
local dependency paths and native line/column ranges.
Existing annotations must not hide a contract that is no longer needed.

Capture native unit-test declarations and original provider evidence before
utility edits. Inspect upgraded dependencies through fresh private Terraform
data directories, not the consumer's stale modules manifest. Remove obsolete
ModTM mappings only with dependency proof and literal same-provider mappings;
preserve other bindings and their comments. Reconcile affected local callers
in dependency order after telemetry transforms. Include every known transitive
local caller of a visited dependency, even when only another example directly
uses the migrated utility; unrelated scopes stay outside this cleanup closure.
Remove provider requirements
and empty mocks only when resources, data, ephemeral blocks, provider
configurations, bindings and the fresh dependency trees prove them unused.
Retain genuine ModTM dependencies, custom mocks, state-only `removed` blocks
and legitimate Random use. Existing safe mock-review rules still apply.
The utility MaPoTF profile owns literal provider-map entry inspection, targeted
ModTM removal, conditional AzAPI insertion and declared-requirement retirement.
PowerShell supplies only fresh dependency-tree and provider-configuration facts,
surfaces the profile's literal-map review before writing, and must not parse,
rebuild or replace authored provider-map expressions.
For scopes with child module calls, defer early ModTM requirement retirement
until the utility cleanup has fresh dependency proof, rather than temporarily
dropping and regenerating a still-required source/version contract.
Before loading a dependency tree, reconcile known local callers against their
children's current native declarations, including callers selected through test
files. Repeat this reconciliation after retiring a child's requirement: Terraform
loads test-selected examples during `get`, before dependency-ordered caller
restoration can run. Remove only unsupported `modtm = modtm` entries; preserve
alias and different-local-name selections. A temporarily retired declaration
may be restored only with the existing fresh dependency proof, after which a
retained mixed map must again forward any genuinely required ModTM configuration.
An intermediate native missing-provider-configuration warning may be tracked
while repairing proven source bindings. All other diagnostics remain fatal,
and a strict dependency recheck must pass before mock migration.
Never transform downloaded dependency source or initialize a backend for this
migration. Preserve consumer initialization data and exact lock bytes, including
failure paths; clear ambient Terraform data/CLI-argument overrides for native
inspection. Drift checks also restore authored source, tests and original backup
bytes, removing only newly created backups.

For modules without their own telemetry, a newly generated canonical `location`
input receives a scoped `terraform_unused_declarations` exemption: the required
interface also applies to global resources that do not consume a region.
Native MaPoTF inspection identifies missing inputs and their generated source
ranges; authored declarations are not annotated. Other unused declarations
remain lint findings. The inline-ignore audit exempts only the exact directive
on the canonical required declaration in a module's `variables.tf`.

The common MaPoTF ordering profile loads AzureRM, AzAPI and Random schemas only
when the current scope contains matching resource or data-source type prefixes.
Provider declarations, aliases, custom local provider names and resources in
called modules do not independently require a schema. Empty and ephemeral-only
scopes need none. Preserve required/optional ordering, promoted AzAPI attributes,
head/foot meta-arguments and source-order fallback for unknown types/providers.
Required schema failures remain errors; unused schemas must not be fetched or
materialized, including on cache hits.
Transform subprocesses receive `MAPOTF_PROVIDER_SCHEMA_CACHE_DIR` and
`MAPOTF_MODULE_SOURCE_CACHE_DIR` under the AVM cache as `mapotf-provider-schema`
and `mapotf-module-source`, respectively, so both honor `AVM_HOME`. Cache
enablement and TTL controls remain inherited. The module-source directory is
used only by MaPoTF versions supporting that cache; forwarding it does not
change the pinned tool version.

Instrumented roots and children run the `root,module,common` profiles; other
module scopes run `module,common`. Profiles execute sequentially so module
provider rules see the generated telemetry. A second `module-call,variable-order,common`
pass visits local modules from deepest to root after their inputs exist.
Examples run `example,provider-cleanup,common`; standalone test modules run
`module-call,variable-order,provider-cleanup` followed by any consumer `test` profile, from
deepest to shallowest after modules and examples finish. Test-wrapper mode
forwards only missing required locations through local calls, adding a required
wrapper input only when needed. Authored call locations, omitted optional
location defaults and telemetry opt-outs are preserved; test wrappers do not
gain `enable_telemetry` inputs or instrumentation. MaPoTF subprocesses
sort variables in a separate profile after creating wrapper inputs, so native
inspection includes the new declarations on the first pass. These subprocesses
clear `TF_PLUGIN_CACHE_DIR` and use target-local providers, so independent
targets can run in parallel without racing Terraform's shared provider cache.

When direct AzAPI use or generated telemetry needs the provider and no
`terraform` block exists, the module profile appends a provider requirement
block to `terraform.tf`, preserving other authored content in that file.
Modules without direct AzAPI use do not gain an unused provider requirement.

`main.telemetry.tf` reads `telemetryIdPrefix` from the module's own
`metadata.json` at apply time. When telemetry is enabled, it creates an
empty `Microsoft.Resources/deployments@2025-04-01` deployment at the active
subscription scope. Its reporting payload is solely the deployment name:
`<telemetryIdPrefix>.<version>.<source>.<instance>[-<key1>-<value1>-...]`. The full version comes
from the matching `path.module` entry in Terraform's modules manifest, with
periods changed to hyphens; an unavailable version is `0-0-0`. The one-letter
source token is `t` (Terraform Registry), `o` (OpenTofu Registry), `g` (Git),
or `x` (other); the raw source path is never reported. The stable instance
suffix is four hex characters derived from `terraform_data.telemetry`'s ID.
When the module already declares `telemetry_additional_content` with the exact
`map(string)` type, its non-null, non-empty entries append after that instance
suffix as sorted, hyphen-delimited key/value pairs. Null map values retain
their key and render as an empty value. Modules without that exact authored
input, and null or empty maps, retain the fixed base name; the transform never
adds or rewrites the public variable declaration. The module catalog maps the
metadata prefix to its canonical type. A precondition rejects a complete name
with characters other than letters, numbers, periods, underscores, hyphens,
or parentheses, or a length over 64 characters; content is never
silently truncated, hashed, stripped, or discarded.

Independent fresh telemetry migrations must produce identical file bytes, not
just equivalent Terraform. Conditional append operations explicitly depend on
all preceding potential writers so an absent earlier transform cannot break
the order. The metadata locals use a literal native block body to preserve
attribute order. The module profile orders the generated telemetry precondition
before the common profile orders its resource body; the pinned native tool
cannot compose those two ordering modes in one profile. Match the generated
resource identity and leave owner deployments, headers and expressions intact.
The first-pass golden remains byte-exact, followed by a second full public
pre-commit byte check and a non-writing pr-check.

The empty template contains the Bicep-style information output and a
non-reporting `apply_id` output set to `plantimestamp()`. This changes the
resource body once per normal plan, forcing an in-place deployment PUT even
on an otherwise no-op apply while leaving the name stable. Refresh-only
plans do not write telemetry. No reporting tags or tier are sent.
The deployment identity needs `Microsoft.Resources/deployments/read`,
`Microsoft.Resources/deployments/write`, and
`Microsoft.Resources/deployments/delete` at the subscription scope; see
<https://aka.ms/avm/telemetry>.

The generated AzAPI resource sets `response_export_values = []`. Root and
direct local-module TFLint profiles configure the `ignored_resources` selector
`azapi_resource.telemetry` only for the generic AzAPI tagging rule and the
generated deployment's TFFR6/7/8 interface rules
(`resource_types`, `retry`, `timeouts`, and `ignore_body_changes`). All other
resources remain subject to those rules, including business AzAPI resources in
the same module; examples retain their existing rule disables. The transform
removes only the prior exact generated tag pragma when it is adjacent to the
canonical untagged telemetry deployment. The lint warning audit reports every
inline ignore, including that legacy pragma, except for the existing narrow
generated location and provider-contract exceptions. The packaged root TFLint
profile disables the retired
`modtm` provider requirement, as the module and example profiles already do.

The packaged AVM TFLint ruleset is pinned to released v1.4.0.
AzureRM remains optional, but declared version constraints must exclude 5.0.0
and later in root, child and example scopes. The existing source and
compatibility checks still apply; excluding individual 5.x versions does not
replace an upper bound.
`avm_output_resource_id_required` applies only to resource roots. The lint
engine derives a root class from the repository ID, AVM folder name, Git
origin, and any declared context scope; conflicting classes fail. Pattern
and utility classes also require valid metadata before their generated root
configuration receives `module_class`. An unknown identity stays on the
resource default, even if its telemetry prefix says otherwise. Child and
example profiles disable this root-only rule. Class settings cannot
contradict the resolved identity, and older custom plugin pins fail with
upgrade guidance. Authored rule-disabling overrides retain their warnings.

The old `modtm_telemetry.telemetry` and `random_uuid.telemetry` instances are
retired through `removed` blocks with `destroy = false`, so upgrading does
not delete their remote objects. The older
`azurerm_resource_group_template_deployment.telemetry` transport and its
`random_id.telem` helper are retired the same way. Recognize the legacy
deployment's name/template expressions, incremental mode and telemetry gate,
and the helper's gate and four-byte length; matching resource names alone
must not remove other authored deployments or random resources.
Retain the helper and its provider if any Terraform source still references
it or the scope contains JSON configuration that needs review.
AzAPI request headers belong to the module owner. Tools must not remove,
retire or rewrite operation headers or their helper locals, including former
AVM header names, conditional expressions, literal strings and merged
`If-Match` preconditions. Adding headers alone must not cause a check failure.
Ordinary Terraform schema and reference validation still applies: owners
must reconcile any references to retired resources themselves. Migrate
standard telemetry output expressions rather than globally replacing text
inside owner-authored expressions.
Terraform must still install their former
providers once when an existing state references them; after the state
forgets those addresses, migrated source does not require `modtm` unless an
unchanged dependency still needs it. The
random provider requirement is removed only if no other random resources
or data sources remain in the module. The transform also removes obsolete
`modtm` provider declarations in examples and standalone test modules when
they have no remaining `modtm` resources, data sources or explicit module
provider bindings. Empty `modtm` test mocks are retired only when the selected
targets' configuration dependency trees prove the provider is unused.
Standard output references to the old telemetry resource are migrated. Direct unit
assertions whose complete condition is `length(random_uuid.telemetry) == 0`
or `== 1` are migrated to `terraform_data.telemetry` only when their selected
target is instrumented. The condition may also prefix that comparison with
a zero-or-one count comparison on `modtm_telemetry.telemetry` or
`azapi_resource.telemetry`, joined with `&&`. Preserve both clauses and their
boolean meaning; other operators, additional terms, indexed/property
references and computed comparisons still require review rather than a
partial rewrite. The counts, comparisons, error message and surrounding
comments are preserved. Native profile inspection must confirm the exact
expression-replacement rule before any test files change. Every reference to
the retired identifier in that file must be accounted for by these assertions;
other uses, including references in comments or strings that prevent that
proof, require review even when unrelated random use retains the provider.
Direct unit tests receive a missing AzAPI mock when replacing legacy ModTM
telemetry, independently of whether an unchanged dependency retains an empty
or non-empty ModTM mock;
empty AzAPI mocks, including comment-only bodies, receive a valid synthetic
subscription resource ID for `azapi_client_config` without losing comments.
Default and literally named aliased AzAPI mocks receive only a missing
client-config block or `subscription_resource_id` default, matching nested
blocks by type and labels and merging object fields without replacing authored
defaults. Before modifying any test file, native reflection must confirm that
the selected binary and profile enable label matching and object merging at
each intended mock address with the exact missing-field update;
older overrides that silently ignore either feature fail with upgrade guidance.
Use an authored literal `subscription_id` to construct its matching
`/subscriptions/<guid>` value; otherwise use the synthetic subscription.
Existing resource-ID defaults, unrelated mocks, comments and expressions are
preserved. Source-backed AzAPI mocks may retain a literal local source directory within
their owning module. Inspect its HCL mock files with native reflection before
adding a client resource ID. Preserve all literal source client defaults in
the inline update and leave source files unchanged; an authored inline
client-config block retains its precedence. Escaping, linked, missing or JSON
sources, source overrides, duplicate client defaults, computed defaults and
nonliteral subscription IDs require review instead of overwriting or guessing.
Downloaded dependency source and legacy telemetry
in scopes without a telemetry prefix are not migrated by the root profile.
Native MaPoTF inspects each direct `tests/unit/*.tftest.hcl` file before source
transformation. Root runs and explicitly selected, known local module
targets, including discovered examples and standalone test setup and wrapper modules,
are supported; remote or unknown targets fail without fetching them.
Load pre-transform provider trees only when preserving existing local bindings
or augmenting an introduced provider mapping needs their evidence. Conservative
local-provider usage checks select those inspections; they never establish
binding coverage. Fully mocked templates can reference inputs that instrumentation
has not created yet, so their native dependency loading waits until after the
source transforms. Every selected post-transform provider tree still requires
complete mock or proven preserved-binding coverage.
When utility planning identifies a target that will gain telemetry, an authored
mapping still requires the same baseline proof even without a root telemetry
profile on that target.
Only root and child modules establish test-file ownership; example and
standalone test targets do not change which files are direct unit tests.
After source transformation, only a target that gained a previously absent,
required `location` input receives a per-run `location = "eastus"` in its
provider-mocked tests. Existing global and per-run values, including nulls
and expressions, remain authored. This test-only value is not a production
default and never replaces per-hub regions or repairs unrelated pre-existing
missing inputs. Assertions, targets and telemetry opt-outs are preserved.
New or unproven real-provider declarations, unproven aliases and partial or
cross-provider bindings still require review rather than being silently changed;
an AzureRM mock alone cannot cover new AzAPI telemetry. Preserve an existing
`azure/alz` library provider only with literal relative library paths without
parent traversal, and existing unmocked `hashicorp/random` and `hashicorp/time`
bindings, when each run's pre- and post-transform native configuration trees prove
the same provider source. Preserve retained declared versions and literal native
provider identities. A generated mapping must retain the selected real library
configuration rather than invent mock outputs or fall back to an unconfigured
library. Unconfigured Random/Time defaults remain implicit; a dependency's proven
HashiCorp source does not require an otherwise unused root declaration.
Never replace an existing mock with a real binding, infer other real provider
implementations, or use another run's source or alias proof. Azure operation
providers and ModTM still require known same-provider mocks.
When generating a new map, retain an already-authored built-in Terraform mock
only when native source evidence identifies `terraform.io/builtin/terraform`.
An undeclared source with both built-in and registry Terraform identities is
ambiguous and requires an explicit source. Do not invent a built-in mock or
silently complete an authored map that omitted it.
AzAPI aliases must have consistent
literal native names, labels and addresses; the same identity checks apply to
every provider alias. Local source-backed aliases retain the source checks
above. An alias is never treated as an unaliased default.
Complete mappings may bind an unaliased target name to its known default mock
or a known alias of the same provider. Aliased target keys still require review.
Prove effective source, mock and mapping coverage separately for every run's
selected configuration tree, including generated mappings and implicit defaults.
A binding in another run cannot cover this run, and authored location or
client defaults do not bypass that proof.
A valid, explicitly empty native run collection needs no mocks. Missing,
malformed or incomplete native collections still fail inspection.
When an instrumented target introduces AzAPI, add its existing default mock
binding only if a pre-transform configuration provider tree proves the old
mapping covered every selected provider through mocks or the preserved local
bindings above. Preserve the original aliases and comments; incomplete or
unproven prior coverage still fails.
Preserve safe authored bindings; remove only bindings to an empty ModTM or
random mock whose provider is absent from that target's
configuration dependency tree. Preserve all remaining expression text and
comments. Before cleanup, account for every retired provider reference in
validated mappings; unexplained references still fail. A default AzAPI
replacement must not be confused with an existing alias. Verify the exact native
mapping update body before modifying any test file. Integration tests do not
receive new mocks or locations.
Non-empty modtm test mocks and remaining
author-owned `modtm` resources or data sources fail with
actionable diagnostics instead of being silently rewritten. Validated ModTM
mocks needed by unchanged dependencies remain authored. Literal alias-only
ModTM or random mocks may be retired natively only when proven unused, with
exact target-address capability checks before writes. When random was
used only by retired telemetry, standard empty `mock_provider "random"`
blocks in direct unit tests are removed if the owner, selected local test
targets, their known local children, and test setup no longer need that
provider. Unselected examples do not retain an owner's random mock; explicitly
selected examples are checked for their own provider use. Non-empty mocks or remaining random
references fail for manual review; mocks for other random use are preserved.
The conservative owner's inspection already covers its known non-example
descendants; selected test wrappers reuse that result rather than treating a
previously inspected ancestor dependency as unknown. Native configuration-tree
evidence covers only reachable dependencies, so independently selected local
targets outside that tree still require their own provider-use evidence.
JSON configurations other than proven locals-only objects and module
dependencies that cannot be checked locally also retain their random mocks
rather than assuming the provider is unused.
Ephemeral declarations count as provider use when retiring legacy requirements.
Preserve the authored source and version constraints of providers used by
ephemeral blocks rather than broadening them to the normal profile defaults.
Native initialization and validation prove these requirements; they do not
establish provider-mocked execution support for ephemeral operations.
When an instrumented unit-test target has no direct random requirement but
still needs its random mock for dependencies, bind its retained unaliased
mocks explicitly in that target's runs, including a newly introduced AzAPI
mock. Inspect each selected target's native provider requirements and its
configuration dependency tree. Exclude state-only providers and other test
targets; passing an unrelated mock to a run is invalid in Terraform. Install
missing modules with `terraform get -no-color` through the shared process helper
with network retry, then inspect `terraform providers`. For an existing lock,
reuse initialized source providers through a private directory link so native
lock checks remain enforced. If locked providers are not initialized, use the
shared backend-disabled initialization helper with compatible selections
preserved instead. Never initialize a backend or fall back to real provider
execution for inspection. Restore the exact original
provider-lock bytes, or its absence, and any existing module-manifest bytes
even when inspection fails. Dependency inspection installs modules into private
Terraform data directories, never the source tree's `.terraform` directory.
Keep these directories alive through requirement planning, then remove them
on transform success or failure without changing pre-existing initialization data.
Requirement planning uses the validated immutable
manifest snapshot captured with the fresh provider tree, not the restored
on-disk manifest; newly added dependencies need no prior manual initialization.
Within one transform invocation, completed inspections may seed later private
data directories with copies of public registry root packages selected at bare,
stable exact versions. Admit packages only after successful native installation,
provider-tree inspection and manifest validation; never read them from the
source tree's existing initialization data. Repair-mode diagnostic trees are not
cache-admission evidence; strict reinspection must succeed first. Fingerprint the complete downloaded
package, reject links, initialization/plan data and unexpected locations, and fail
if an admitted package changes before reuse. Discover current calls and known local parents through
native MaPoTF inspection before remapping package keys. Scopes with Terraform
overrides or JSON other than proven locals-only configuration bypass seeding,
because native call reflection is not complete for those inputs. Local module
contents, version ranges, Git/URL/private-registry sources and registry subdirectories are
not reused. Every target still runs Terraform installation and provider inspection
to revalidate its graph, and its resulting manifest is captured independently.
No provider or backend data is copied. Package reuse ends with the invocation's
inspection-directory cleanup; it is not a persistent or cross-repository cache.
Validate root/default-directory test targets before module installation can fetch
them. Inspect every target's direct JSON configuration with the shared
locals-only validator before installing dependencies. Other JSON configurations,
JSON tests, possible backend/cloud declarations and initialized backend
metadata require review before dependency inspection;
do not access remote state to construct mock mappings. The test
owner's requirement does not cover a separately selected local target.
Preserve assertions and mock defaults without restoring unrelated unused provider
requirements. A proven retained provider source/version contract may receive an
inline `terraform_unused_required_providers` exception on that declaration only.
Require fresh native source evidence and a surviving incoming explicit provider
binding, native unit mock/type contract, or protected original version contract;
child usage or an old declaration alone does not justify an exception.
Inspect the current native test declarations
after migration, not mocks that have already been retired.
Use the pinned TFLint JSON source range to place the comment after final map
cleanup; do not parse HCL in PowerShell or disable the rule for unrelated
unused declarations. Insert multiple comments in reverse native source order
so earlier edits cannot invalidate a later declaration's range.
Transform therefore also requires pinned TFLint when inspecting provider
retirement or retaining these contracts.
Pre-commit and transform-only prerequisite selection must therefore include
the pinned TFLint executable even when the lint step is excluded.
Surface Terraform's known redundant-empty-provider deprecation while preserving
the authored configuration; it is not a provider-tree node or permission to
accept unknown diagnostics. Missing provider configurations still require the
existing repair mode and a subsequent strict inspection. Unknown warnings,
errors and alias/type failures remain blockers.
Verify native profile support for
the complete mapping before changing any test file, and keep repeated
transforms and non-writing drift checks stable.
Validate unsupported retired-identifier references before removing any mock
or backup. Snapshot every test file that cleanup can modify, including files
outside direct unit-test plans. A later migration or cleanup failure restores
their full original bytes even in normal writing mode; explicitly report any
file whose restoration cannot be verified.
For unchanged ModTM dependencies, preserve the mock and every required run
binding. Proven default mocks continue to bind implicitly; restoring their
ModTM source requirement alone must not manufacture a native test `run.providers`
map. A removed non-default provider source must not become an inferred
`hashicorp/modtm` source. Restore only a selected target's proven
`Azure/modtm` requirement, retaining its original source and version when
available. Dependencies without an explicit module-call provider map inherit
the default configuration; never synthesize identity forwarding maps for them.
Augment only an existing explicit map that still needs a default ModTM entry,
preserving its aliases, other bindings and comments. Known local intermediates may receive the same repair;
known local callers and example wrappers also receive only their proven
required source declaration and any necessary existing-map augmentation. Newly synthesized
requirements preserve an available original version constraint; otherwise
inherit only literal constraints from their proven same-source required
dependencies or local targets. Combine distinct inherited constraints by
intersection, without inventing a pin from installed versions. Missing or
nonliteral constraint proof requires review; existing authored requirements remain
unchanged. Default and complete example-wrapper regressions must check both
required-provider and unused-provider lint as well as independent validation,
exact dependency selections and lock/manifest bytes. Finish the normal
ordering profile on restored scopes so the first pass is already drift-free.
Restore requirements and bindings through the isolated `provider-restore`
profile, not the full module profile: example and test callers must not acquire
unrelated module inputs or changed provider constraints during this repair.
Published dependencies remain untouched. An inspected target's or dependency's
direct `.tf.json` files may contain only `locals` blocks in strict JSON objects,
including arrays of locals objects; empty configuration objects are also safe.
Inspect every such
file with the same validator without evaluating expressions or rewriting its
bytes. Proven locals-only JSON does not retain otherwise unused provider mocks.
Provider source, version and binding proof still comes from native inspection
of their HCL. Computed or aliased module bindings, other JSON dependency blocks and
unproven source inheritance require review. Nonlocals JSON in selected
inspection targets and all JSON tests retain their pre-installation review guard.
Verify the exact native source update and object-merging capabilities before writes.
Unrelated selected targets still retire their unused bindings and requirements.
Native regression fixtures use loopback-only ModTM endpoints and verify mocked
resource values, full original locks, installed selections, repeat stability
and failure-path drift restoration without production collector access.
Real ALZ library regressions preserve provider configuration, fixture bytes and
assertions through native parsing, provider-tree inspection and validation;
they do not execute the original Terraform tests or fabricate ALZ outputs.
Separate binding regressions execute only with proven default and same-provider
alias mocks, including Terraform's built-in provider. Native execution rejects
real provider blocks, missing dependency mocks and unproven mappings before
`terraform test`; inherited credentials are cleared, authentication fallbacks
disabled and runtime endpoints/proxies restricted to loopback. Preservation
and mocked-binding evidence do not establish original consumer/runtime
equivalence, which remains an explicit qualification gap.

`avm pre-commit` and `avm pr-check` resolve their required tools before the
first step, which validates metadata for the selected root and its module
children. Missing or invalid metadata fails and stops either chain before
other steps, without changing module files or reading indexes. `avm pr-check`
also requires a clean worktree before tool resolution. `-Verbose` logs the
discovered module count, each validated metadata path, and any issues.
Terraform pr-check initializes missing source examples with the backend disabled
and compatible locked dependency selections preserved. Validation must not
request dependency upgrades. Incompatible locked selections fail initialization
without an upgrade retry; candidate-tree checks still reject tracked lock drift.
`avm pr-check -ExcludeSteps` accepts an array of any of its nine check names:
`metadata`, `sync`, `format`, `transform`, `lint`, `check policy`,
`check convention`, `validate`, and `docs`. Names are case-insensitive and
validated before execution; an empty array keeps the default chain. Explicit
exclusions bypass only those steps, including the metadata stop and required
Bicep result checks for an excluded step. Each is reported as `skipped` with an
exclusion reason. Non-excluded checks retain their ordering and failure rules;
version and clean-worktree guards remain mandatory. An entirely excluded chain
reports overall `skipped`, not `pass`.
Terraform source-example initialization is an explicit `initialize` step with
its own start/result logs, structured result and duration, consistent with
pre-commit. It runs once after selected metadata validation and before the
remaining checks only when `validate` is enabled; excluding `validate` also
omits `initialize`. The default Terraform chain has ten steps; Bicep retains
nine. Validation reuses the persistent initialization state.
Initialization failure aborts dependent checks even without `StopOnFail` and
cannot be reported as skipped.
Formatting needs the Terraform executable but no initialized examples. Transform,
lint and policy prepare their own working directories and retain their existing
cache and policy-isolation contracts when validation is excluded.
For Bicep formatting, `avm pr-check` compares `bicep format --stdout` with
the original source bytes and never rewrites the working copy. `avm pre-commit`
still formats in place.
The Bicep transform compares the exact bytes from `bicep build --stdout`
with each module's main.json. Pre-commit writes missing or stale output only
after all selected modules build successfully, with rollback on write failure;
`avm pr-check` reports each missing or stale artifact with an `avm pre-commit`
remedy and never changes repository files. Compilation requires a nonempty,
valid ARM template and checks process exit codes even when diagnostics do not
parse. Generated JSON is not part of one-time `avm init`; README generation
remains a separate migration slice.
Explicit `avm metadata validate` and `show` still fail for missing files.
Discovered helper children are validated; existing test, example, and
internal-only source-directory exclusions remain unchanged.

The catalog workflow lives in this tools repository and generates entries only
from valid module metadata. Helpers remain in catalog JSON under `helper`, with
stable repository/module-path identities, inherited owners, the derived family
`moduleType`, and null ARM `providerNamespace`/`resourceType`. Every generated
CSV omits them, including previews and canonical outputs. Invalid present
metadata is an error; missing metadata never causes a full legacy CSV record
to be retained. Generation holds back affected outputs when protected source
CSV module identities would disappear; publication independently enforces those
holds. Valid Bicep submodule paths below `avm/{res,ptn,utl}/{group}/{module}`
may disappear without `Force`, including helpers and deeper children. Root
records, malformed or unresolved identities, and Terraform submodule rows remain
protected.
Validated deprecated/unpublished records are retained as `excludedModules` in
the hash-protected migration report. Only their exact resolved implementation
identities are also exempt from this removal guard, without `Force`; malformed,
inconsistent, or mismatched exclusion evidence fails publication.
Explicit `Force` permits other removals only, not other validation failures.
Other Terraform helper source rows remain subject to the removal report and guard.
Source CSVs, not existing preview outputs, are the comparison baseline; this
remains true after canonical CSV replacement. Hash-protected source-row evidence
is checked again against the unchanged publication base before writes.
Matched-row compatibility fields and published Deprecated status remain preserved.
The one-off migration and canonical CSV replacement remain explicit operator
actions.
Metadata is owner-authored, not a managed-file
overlay that can be replaced on every repository sync.
Terraform repository discovery admits installed repositories by the shared
case-insensitive module naming regex, without built-in or caller-supplied
exclusion lists. Nonmatching repositories are logged and ignored without
warnings, errors, issue artifacts, or metadata requests. Archive filtering and
explicit repository-ID selection still apply to matching modules. Discovery
reads validated root metadata from each selected repository's default branch.
Missing files warn during rollout and suppress
direct collaborator cleanup; invalid files or API failures exclude that
repository. Archive state comes from GitHub, not an authored metadata field.
New-repository creation (`avm init`) initializes metadata before the first
commit without a tools-local CSV registration. Organization rulesets require
pull requests on `main` once a repository is marked active, so its initial push
temporarily sets only `global-rulesets-opt-out` to `true`. The original value
and the repository ID are recorded in the user's Avm state folder first, then
the value is restored and verified on success or failure. A later run restores
a recorded value left by an interrupted run only while the property is still
`true` and repository sync does not manage the repository; a record for a
deleted repository of the same name is discarded. A `true` value with no
record stops the run because its original value is unknown, unless repository
sync manages the repository; sync's own ruleset also requires pull requests, so
such a repository without module files is not pushed to directly.
Existing repositories use normal
reviewed updates; generated public catalog CSVs are unaffected.
The current one-off Terraform migration is agent-led and metadata-only because
source inference is ambiguous. It uses a reviewed inclusion/exclusion inventory,
preserves valid existing metadata and owners, and creates no Terraform wiring.
All selected helper submodules receive valid metadata marked `helper`,
superseding their previous one-off omission. The excluded `test-repo5` root and
archived/missing/private repository restrictions remain unchanged. Migration
data remains outside the packaged module. Compatible installed/released schemas are required
for adoption; successful checkout validation or CI is not a release.
Terraform sync never creates missing metadata files or infers values from CSV
indexes. Existing repositories use owner-authored files or the reviewed one-off
migration; ordinary authoring still uses the installed release. Bicep files
were added directly to the module repository rather than through Bicep Sync.

### Bicep documentation

`avm docs -Ecosystem bicep -Path <repository-or-module-root>` renders root
and child READMEs through the pinned `bicep docs generate --stdout` command.
Module-root runs include tests in that root's `tests/e2e` for its own and
nested READMEs, but do not search above the selected root. The
packaged `avm-readme-v1.scriban` is used by default without creating caller
config or template files. Bicep 0.48 resolves templates only from configuration;
package-default renders use a temporary copy of the selected source/config
tree (owner-only on POSIX), with the canonical template selected only in that copy. The copy
preserves relative sources, binary assets, compiler options and example
reassignments, excludes Git administration data, and is reused across modules
and provenance renders in one invocation. It is removed on success or failure.
Linked entries and filesystem/home/temporary-root staging are rejected rather
than following links or copying an unbounded directory.
An explicit `documentation.template.file` in the nearest `bicepconfig.json`
must reference a relative canonical copy; a different template or hash fails
before writing. Valid explicit configurations render directly without a
temporary source copy. Generated content comes from the
native model, Bicep test sources, and compiled `main.json` (or a local build
when it is absent), never from the existing README body.

Authored Notes belong in `README.notes.md` next to the module source. Run
`avm docs export-notes` once to extract an existing Notes body; it does not
overwrite a sidecar. Documentation generation rejects an existing README
with Notes but no sidecar and does not change source files. `-CheckDrift`
compares raw UTF-8 bytes without writing. `-IncludeRenderedContent` requires
drift mode and returns generated `{Path, Content}` values for an independent
comparator. A Bicep compilation failure is reported per module in drift
mode; a source-less README is explicitly identified rather than reported as
generated.
Drift mode can report a warning rather than stale only when the tracked
README omits complete generated required/non-required grouping-comment
pairs. A private, non-writing docs render marks only those comments in
first-party example JSON values; removing the unpredictable markers must
reproduce the normal rendered README exactly before the marked pairs can
qualify. Authored descriptions cannot acquire these markers, even if they
contain convincing headings, fences, or complete example frames. Partial
pairs, changed prose, code, types, examples, outputs, and any other byte
differences still fail. Unused child-example aliases carry no rendered
markers and are ignored; a half-rendered alias fails closed. The accepted
pairs are not tied to a module name or fixed count, and normal generation
writes the unchanged renderer output.
An unavailable private render reports an error. This local comparison
behavior does not waive the full-registry qualification limit below.
Referenced module test examples are validated against the compiled
parameters of their actual target `main.bicep`, including tests assigned
to a child README. Unknown names or omitted required parameters fail
that README with the test path and parameter names in the error; drift
mode reports the failure per module, and normal generation writes no
READMEs when any module fails. Invalid tests are never published as
successful usage examples.

Do not replace the registry's existing generator or CI, bulk regenerate
READMEs, or release this migration until an independent comparison shows
exact bytes for every source-backed README, apart from eight JSON-example
comment lines absent from the checked-in `avm/res/key-vault/vault/README.md`,
and separately verifies all source-less README bytes. Report that historical
exception explicitly; keep the comments in generated output, as the legacy
generator emits them. Every other byte remains subject to the comparison.
At registry commit `82bab0404566557b9fb5efdc9780bb5ce438030b`,
an offline render with the published dependencies and pinned Bicep CLI
produced all 575 source-backed READMEs. An independent comparison found 574
byte-identical matches and only the eight proven generated Vault comment
lines; the three source-less README files matched their tracked Git blobs
without being counted as rendered. The required `avm pr-check` docs
step enforces later README drift; this qualification alone does not authorize
removing the registry CI workflow or its other gates.

### Bicep deployment tests and cleanup

`avm test e2e` compiles selected `tests/e2e/**/main.test.bicep` cases into
temporary ARM templates before cloud execution. It supports resource-group,
subscription, management-group and tenant scope, including nested and
cross-subscription deployments. Preserve the complete authored template:
locks, assignments and repeated `init`/`idem` deployments are not stripped.
`AVM_OFFLINE=1` adds `--no-restore` to compilation; it does not make a
deployment command an offline test.

The native runner adapts the registry's ordinary cleanup; the reaper is
only a fallback. Explicit test targets are required. Cleanup follows
recorded `Create` deployment operations recursively, not `Read` references
or a subscription-wide inventory. ARM `Create` operations can represent
updates to existing resources, so those resources can also be removed.
Only run reviewed test sources in targets authorized for that lifecycle.
Resource-group entry points use a new, uniquely named group with a verified
run tag. Never delete the existing management group selected as the execution
container. Exact provider-container operation IDs may expand only within
their named resource group and provider namespace.

Use the caller's existing Azure PowerShell session with process-scoped
subscription and tenant selection. Verify the selected account and cloud,
restore the original context even on failure, and stop if restoration fails.
Azure CLI and PowerShell must confirm the same subscription, tenant, cloud
and account before CLI cleanup. Do not log in, export tokens or install
modules implicitly. The native dependency floors follow the Az 15.5.0
bundle, plus Az.Subscription 0.12.0, which is distributed separately.
Check the actual command provenance and parameter names or aliases.
Make the selected Az.Accounts version visible in the current PowerShell
process's global scope before importing other Az modules: nested clients
perform their own global Accounts lookup. Other dependencies remain
module-scoped. This does not change persisted contexts or install modules.

Explicit parameters or an ARM parameter file override opted-in CI inputs.
`-UseCiInputs` accepts `AVM_CI_VARIABLES` and `AVM_CI_SECRETS` JSON:
secrets override variables; `CI_` removes underscores and takes precedence
over the underscore-preserving `CI__` alias within one source. Keep typed
numbers, booleans, arrays, objects, secure values and vault references intact.
Tokens are replaced in temporary templates and recursively in in-memory
parameters, never in authored source. Scope tokens belong to explicit
target inputs. `keys` and `count` remain valid authored names.

Subscription pools use a seeded, order-independent permutation and
round-robin case assignment within the selected tag, rather than the registry's
`Get-Random` permutation. Explicit subscription selection takes precedence over
ambient CI pools. Pool input precedence is Variables `VALIDATE_SUBSCRIPTION_IDS`,
Variables `TEST_SUBSCRIPTION_IDS`, Secrets `VALIDATE_SUBSCRIPTION_IDS`, then
Secrets `TEST_SUBSCRIPTION_IDS`; directly supplied environment aliases follow
the same canonical-before-legacy order. Management-group metadata uses the
same source order, with `VALIDATE_MANAGEMENT_GROUP_ID` before `ARM_MGMTGROUP_ID`
within each source. Authentication remains `VALIDATE_*`, not legacy `ARM_*`.
Native e2e uses that management-group target only with `-UseCiInputs` and
only when `-ManagementGroupId` was not explicitly supplied. An explicit
target wins even when invalid; validation must reject it rather than
substitute a CI target. Without the opt-in, management-group execution still
requires an explicit target. Missing or invalid selected targets fail before
authenticated execution or deployment. Static policy selection and scopes
that do not require a management group retain their existing behavior.

Registry-layout native execution and PSRule require the exact root
`.reserved-test-subscriptions.json` file: an object mapping canonical module
paths to subscription tags. Validate the entire regular, exact-case UTF-8 file,
at most 64 KiB, including unrelated entries and duplicate keys. Keys and lookup
paths match case-sensitive
`\Aavm/(res|ptn|utl)/[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)+\z`.
Match exactly, without trimming, case folding, path normalization or parent/child
inheritance; unmapped modules use `General`. Validate every pool entry before
filtering, reject canonical duplicate GUIDs across tags, and retain each record's
original zero-based index and ID spelling. Its key is lowercase SHA-256 hex over
UTF-8 lowercase canonical GUID `D` text. PSRule uses the first matching entry.
A configured pool without the required tag never uses another tag or the legacy
singleton.

`Select-AvmTestSubscription` exposes this shared read-only selection to workflow
callers. Require an explicit repository `Path`, exact `ModulePath` and complete
`TestSubscriptionIds` pool; do not read ambient aliases or synthesize a fallback.
Optional `Example` matches an exact runnable directory or test-file path through
native recursive discovery and selects the actual owning module's reservation.
Return that canonical `ModulePath` with the original pool `Index`, `Key`,
`SubscriptionId`, `Name` and `Tag`. Callers retain `RandomSeed` and `CaseIndex`,
repeat selection before authentication and verify the original binding.
`PrivateData.AvmCapabilities.BicepTestSubscriptionSelection = 1` identifies this
package API, not a released version or permission to run reserved infrastructure.

Native e2e cannot orchestrate reserved preparation or its full environment lock:
reject non-General mapped cases before compilation, features, hooks or deployment,
including recursive selections and split-phase completion. Direct them to the
protected registry workflow. That workflow must hold `avm-hci-<subscription key>`
with `queue: max` across preparation, tests and confirmed cleanup, separately
from module locks; unfinished or uncertain owned environment state blocks reuse.
Tools does not prepare HCI infrastructure or assert that these external safeguards
have run. Standalone General tests retain their existing explicit-target behavior.

Resource placement uses the owning module's canonical resource
type when available; pattern/helper or absent metadata uses the generic
allowed-region list. Explicit parameter, token and resource-location pins
must agree. Only wholly regional validation failures can relocate an
unpinned, non-global, non-resource-group case. Metadata location and
`baseTime` stay fixed.

`Resources/bicep/retry-policy.json` and its adjacent schema own retry matching
rules, modes, region choices, submission/region budgets, delay and read/observation
budgets. Validate the packaged policy before execution: reject duplicate or
unknown fields, invalid expressions and inconsistent rules. Expressions have
bounded evaluation time and cannot execute code. Public attempt limits may
lower, but not exceed, the configured budgets. Code retains unconditional
identity, response-shape, authentication, cancellation and cleanup guards;
configuration cannot turn those failures into retries. Every failed error
branch must support the same configured mode; mixed or unknown evidence stops
retrying. There is no catch-all replay for a failed or rejected deployment.

The case uses one bounded submission loop with two modes. `InPlace` preserves
the exact root deployment identity, validated template, resolved parameters,
external naming context and region. `Fresh` generates another external naming
context and root identity; resource-group cases create another uniquely named,
tagged group. Fresh normally chooses the next eligible region, with rejected
regions and validation attempts carried forward. A policy may instead preserve
the region while generating a new context. A pin or exhausted region budget
must not silently change a next-region retry into an in-place retry.
Generate only harness-owned naming tokens and their derived inputs anew;
explicit caller values and Bicep-authored names remain unchanged. Fresh means
a new external attempt context, not guaranteed isolation of fixed or global
names inside Bicep. Do not add naming-eligibility or ARM what-if gates to retry.

Provider/location, deployment-record, operation-page and assertion-output reads
buffer each attempt and discard partial failed output. Each idempotent read
independently defaults to three attempts for typed request timeouts through
the shared retry mechanism with a five-second initial delay. A later page's
retry must not replay earlier pages. Any HTTP status, permission,
authentication, cancellation, unknown sibling cause or untyped transport/
message-only failure disqualifies the read retry. Traverse both inner exceptions
and distinct RuntimeException error-record causes. This exception to the normal
Azure SDK retry boundary does not change shared retry defaults or apply to
mutations.

Regional evidence includes the registry's captured small Linux container-group
capacity message, wrapped ML/Cosmos high-demand response, AKS preflight
response with an explicitly empty supported-zone list, and exact
`LocationNotAvailableForResourceType` provider-availability response. The latter
must name the selected region and a valid provider-qualified resource type,
with a distinct non-global available-region list that excludes the rejected
region. Exact Search SKU-capacity, semantic-availability and
service-capacity `InsufficientResourcesAvailable` responses
qualify only for the selected non-global region. Container Apps managed
environment capacity requires its complete AKS diagnostic envelope, matching
strict JSON body and recognized, unique diagnostic headers. For these service
responses, every supplied ancestor or leaf target must be a consistent service
identity or deployment in the selected subscription; Container Apps requires a managed-environment
identity, while untargeted Search messages are allowed. Keep target ancestry
separate for each error path. A selected candidate or resource ID alone does
not establish the failed region for regionless service errors.
Normalize null SDK `target` and `details` members only on the copied
error node; preserve the original response and reject meaningful, empty,
malformed or unknown extra fields in narrow evidence. Require the matching
region and resource/subscription context, complete error structure and no
mixed or malformed evidence; do not generalize these to arbitrary messages.
Record every attempt before submission and verify the native response's exact
deployment ID. Deployment retries require an exact Failed root and complete
eligible operation evidence, not preflight rejection alone. A submission
timeout watches the same deployment
under one absolute UTC deadline shared by every attempt and recovery route
in the case. `observation.coordinatorTimeoutSeconds` defaults to four hours
and can only be lowered. Do not reset the deadline on a fresh/in-place attempt,
start another status read at/after it, or accept a terminal result returned
at/after it. Clamp the final sleep to the fractional time remaining.
Direct private observation without a coordinator retains its one-hour default.
Three consecutive read timeouts still stop observation; a
recovered `Failed` state counts as confirmed. Unknown or cancelled outcomes
never resubmit. Before either retry mode, strictly discover the failed attempt's
terminal root and nested Create operations and atomically save the union of
resource identities. Partial discovery is saved but blocks replay. This snapshot
is read-only: never remove resources, purge soft-deleted names or delete
deployment records between attempts. ARM may overwrite nested history even
when root names differ. Final cleanup merges current discovery with saved
evidence from every attempt, including failed or abandoned attempts, and safely
deduplicates resource identities without case sensitivity.
Subscription and management-group submission capture the authenticated context
before recording an attempt and use that profile for submission and status reads.
At subscription scope, an exact SDK nested-operation GET 404 may also observe
the original root: require matching request, typed HTTP status, SDK body and
strict JSON evidence for a different deployment in the same subscription and
original cloud authority. It never authorizes another submission itself.
Only separately confirmed Failed state and eligible operation evidence can
permit retry after recovery; successful recovery never enters classification.
For management-group submissions, an actual typed HTTP 403 may only observe
that same deployment within the
existing recovery budget: success requires its exact ID, scalar state and
valid outputs. Failed, missing, malformed or unreadable recovery never permits
replay or regional classification. Cancellation remains terminal and takes
precedence over HTTP 403, which takes precedence over timeout or transport.
Keep original and recovery errors in memory without logging raw Azure payloads.
An unclassified submission exception may be recovered only by an exact Failed
root record and complete eligible operation evidence; a malformed returned
identity or unreadable classification must never enable replay.

The default policy assigns narrowly targeted `InternalServerError` leaves for
application gateways, private endpoints and PostgreSQL flexible servers to
`InPlace`, and the supported capacity/region failures to `Fresh`. Adding a
service rule must not require another service-specific execution branch.

Strict discovery may omit a nested deployment only after a unique failed
preflight Create operation in the complete parent history and explicit
`DeploymentNotFound` from an exact child-record GET. A missing operations
page alone is insufficient. An ID-less Graph service-principal Create may
be ignored only when a successful operation and that exact deployment's
exported template prove the matching literal existing declaration, extension,
import and scope. This proof also applies during ordinary final cleanup;
never reuse a parent deployment's export for a child. Both cleanup and retry
classification read deployment operations with API `2025-04-01` to preserve
extension metadata; record and resource-group reads remain unchanged.

After a successful deployment, pass its exact REST outputs to case-local
Pester assertions, then run `post.ps1`, then cleanup. Output envelopes support
the Azure PowerShell `Type`/`Value` properties without changing authored
object keys or array shapes. Assertions and hooks run in the caller's
PowerShell process to retain process-only authentication; caller/workflow
cancellation applies instead of separate-process time limits. Restore the
selected Azure context around each phase. Assertion/hook failure still
attempts cleanup; cancellation retains state for deliberate recovery.
Existing suites must run completely: skipped, filtered, inconclusive, empty
or setup-failed suites are not passes. An absent suite is `not-present`.
Module-owned unit Pester remains isolated under `avm test unit`; static
authoring checks remain under `avm pr-check`, without deployments.

`-Phase All` is the normal lifecycle. `Deploy` retains resources and state;
a caller can renew its sign-ins before `Complete`, which never compiles or
submits another deployment. Completion requires the explicit state-matching
subscription and tenant and fingerprints the selected `main.test.bicep`,
owning `main.bicep`, discovered assertions and case-local `post.ps1`. This
is not a fingerprint of every imported helper or the whole checkout.
Save completion-started state before running authored scripts; interrupted
or repeated completion must use `avm test cleanup`, not replay those scripts.
`-KeepResources` runs assertions but skips both the post hook and cleanup for
all attempts; this is an explicit debugging exception to end-of-run cleanup.
Cancellation or context-restoration failure also retains the complete saved
evidence for deliberate cleanup rather than deleting possibly active resources.

The private version-1 JSON state allows only target identifiers, status,
verified group ownership tags and the small amount of resource metadata
needed after deletion, plus the case path, source fingerprint and
completion-started marker. An optional attempt journal records contiguous
submission numbers, mode, naming ID, root ID, group and region. Validate its
case/scope ownership, in-place identity reuse, fresh identity changes and
coverage of every recorded root. Older version-1 states without the journal
remain readable. The state never stores credentials, parameter values,
deployment outputs or raw Azure responses. Create a unique local temporary
file by default; an explicit path resolves against the caller's PowerShell
location. Never overwrite an existing file during creation. Updates use a
flushed, exclusive sibling temporary file followed by an atomic replacement,
and retain the last valid state if serialization fails. State survives
temporary-template and parameter-file cleanup.
Failed/rejected root entries may additionally retain `recordDeletion` as
`Pending` or `Complete`, only after all saved resources are post-processed.
An accepted history DELETE is not confirmed absence. Persist progress and
verify exact terminal record/404 responses. An exact `Deleting` record is
allowed only during post-delete confirmation, consumes the existing bounded
polling budget and never proves absence or permits pre-cleanup removal.
Reject malformed confirmation responses without logging raw payloads.
Cleanup-only recovery confirms
pending deletion with GET without repeating DELETE or rediscovering those
roots. Pending history deletion prevents a Complete outcome. These fields
do not permit nested root entries or authorize another deployment retry.

Capture post-removal metadata before deleting resources or their parents.
Ordinary role assignments are removed by exact validated ARM ID with
`DELETE ?api-version=2022-04-01`, without Graph principal resolution or broad
role enumeration. Only typed HTTP 200, 204 or 404 confirms removal/absence;
202 and malformed/error responses remain failures. Scheduled/PIM role cleanup
retains its separate APIs.
If the native SDK reports a plain, unclassified named-group failure without
HTTP metadata, verify only that group with an exact ARM GET in the selected
subscription. Treat it as absent only for HTTP 404 with the structured
`ResourceGroupNotFound` code. Never infer absence from error-message text,
or probe after typed authorization, transport, timeout or cancellation errors.
Persist successful removal before post-processing so recovery retries only
unfinished work. Partial discovery, unverified ownership and exhausted
cleanup remain explicit failures with pending targets; cancellation and
context-restoration failure must not enter the ordinary retry loop. Pending
cleanup stops later cases. `avm test cleanup` requires matching explicit
subscription and tenant IDs, needs no source checkout and never runs authored
scripts. Completed state is a local no-op. Resume only trusted state files.
An Actions caller may upload the non-secret state as an artifact. Recovery
from that artifact requires a completed upload; runner loss beforehand
still relies on the reaper or operator cleanup, not a new external journal.
An artifact must also be retained when a deployment phase fails after
creating state; a failing command does not mean no resources exist.

### Shared Bicep workflows

Tools owns the top-level reusable `bicep-pr-check.yml` and `bicep-release.yml`
entrypoints, the established six reusable `bicep-module*.yml` legacy leaves, and
the package-runtime Bicep module leaves. The registry retains thin event callers,
ordinary module callers, source, authored tests and configuration, including its
legacy child-publication approval configuration and validator.
Shared native validation and execution belong to the released `Avm.Authoring`
package, not registry utilities or copied compliance scripts.
Reserved Azure Local cases retain registry-owned legacy execution until
equivalent native coverage exists. The tools entrypoints
partition generic selections with the caller's existing reservation helper.
Non-General selections retain explicit, immutable reverse calls to the registry
legacy preview and publish-only workflows. Relative reusable calls inside tools
cannot select a registry workflow. This is a legacy compatibility exception, not
migration of that implementation into tools or a new prepared-HCI, mapped-identity
or full-environment-lock guarantee. Preserve its existing behavior; do not
duplicate the reservation inventory, route reserved cases into ordinary native
execution, or change the ordinary registry module workflows and publication
approval policy as part of the thin-caller contract.

Both entrypoints expose no `workflow_call` inputs. PR checks use the original
caller's `github` event context. Automatic upstream PR checks admit `opened`,
`reopened` and `synchronize` without a static-check label. A `labeled` event is
admitted only when adding `PR: Run E2E Tests`; that label alone enables deployment
for internal PRs. Other automatic repositories and event types are not admitted.
Fork PRs always run only the public-data static tier, irrespective of labels:
packaged compliance and authored unit tests, with empty `AVM_CI_VARIABLES` and
`AVM_CI_SECRETS` maps, no inherited secrets, OIDC, identity or subscription
selection. Report protected policy and deployment tiers as not run, never as
successful static results. Manual check dispatch has only `modulePaths`, an
explicit comma-separated selection; it runs static, policy and deployment
validation with cleanup and normal location defaults, without PR-label lookup
or publication. No operation, phase, cleanup or location toggles are exposed.

The release entrypoint is separate from checks and needs no OIDC permission.
It only discovers publishable changes and creates module release tags through
the existing approval and ADO publication path; it never runs validation,
deployment or identity/subscription selection. The registry release caller
enables manual dispatch, with the intended main-push trigger commented out
until a separately approved activation.
The entrypoint always enables the internal pre-tag changelog guard. The shared
tag planner must validate notes for every refreshed calculated child/parent
target before creating or pushing any tag in that module's release plan.

Callers pin the entrypoint `uses` reference once to a durable, merged tools
commit SHA; an orphan premerge head or mutable branch is not the publication
contract. New Bicep orchestration uses only relative reusable workflow calls
from that entrypoint revision and the latest stable PSGallery `Avm.Authoring`
package. It must not check out tools again, pin a second tools SHA, use
`@main`, derive a source ref, or accept a caller-facing `tools-ref` override.
The runtime package must declare exact integer
`PrivateData.AvmCapabilities.BicepWorkflowOrchestration = 1` before selection
or release work and `BicepWorkflowE2eRuntime = 1` before E2E selection or
authentication; an unavailable published runtime fails explicitly rather than
falling back to repository scripts. Package qualification must exercise this
package-only path, including empty fork configuration, InPlace/Fresh retries,
artifact state, and final-only cleanup; interface-parameter checks alone do
not prove that behavior.
Direct callers of established legacy leaves continue to pin their tools `uses`
reference and `tools-ref` to the same full immutable SHA. Nested reusable calls
remain relative to the entrypoint revision. Executable package-runtime jobs
check out only the complete caller at its intended target. Ordinary callers
retain `github.sha`; generic callers forward their checked `targetCommit`
through every validation tier.

For generic pull requests, `pullRequestHeadCommit` is the event's head SHA.
The checked-out target must be the tested merge with exactly two parents:
its second parent must match that head, and its first parent is the only
comparison base. Ignore the mutable event base; never substitute a branch
tip or merge-base. Unavailable or malformed merge history fails before
matrix outputs. Pushes retain their before-to-target comparison and
static-only all-module fallback when the base is unavailable; manual
selection does not inspect pull-request history.

Static validation invokes `Invoke-AvmTestUnit -Recurse -IncludeCompliance`
only after the package declares integer
`PrivateData.AvmCapabilities.BicepPackagedCompliance = 1`. A compiled asset
alone is not acceptance. Policy uses the public Bicep-only `Example` and
`Baseline` selectors; omission retains defaults/WAF-aligned examples and
all four baselines. Explicit examples may select another authored e2e case;
invalid, unmatched or incorrectly cased selectors fail. Required baselines
are `Azure.Pillar.Reliability` and `CB.AVM.WAF.Security`; `Azure.Default`
and `Azure.Pillar.Security` are advisory. Missing dependencies, empty results
and uninspectable evaluations still fail.
Packaged policy supplies the registry's static-only
`builtInServicePrincipalObjectId` placeholder through PSRule parameter defaults.
It does not write consumer source or supply a native deployment parameter.

Policy preparation requires integer package capability
`PrivateData.AvmCapabilities.PowerShellModuleArchiveRecovery = 1` and the
reservation-aware `BicepTestSubscriptionSelection = 1` capability. Resolve
PSRule and PSRule.Rules.Azure with `Get-AvmTool` at the same caller module
path used for validation. Reuse the exact installed or managed-cache versions;
prepare missing packages through `Install-AvmTool`, including its pinned
dependencies, then confirm readiness. Do not maintain a second package
downloader, custom repository or direct policy dependency installation in
workflow support. The native installer owns checksum validation, download
staging, bounded local archive-corruption recovery and atomic publication.
Retain the installed release's exact dependency pins and repository overrides,
not a prerelease lookup. Bootstrap or import failures are errors
even for advisory baselines; advisory rule findings remain warnings.

Only requested, nonignored Azure cases require identity selection. Static,
policy, discovery, release preview and tag-only execution must not require
the module identity mapping or Azure login. Empty and wholly `.e2eignore`
selections need neither identities nor a subscription pool or compiler.
Generic/bulk Azure execution remains supported.
Generic preview and publish workflows with an empty test list skip the
protected subscription-selection job rather than requesting an unused approval.
Dispatch and phase-control JSON uses one package-independent flat scalar
reader. Preserve date-looking strings without DateTime conversion, retain
boolean conversion and empty/null omission, and reject nested object/array
values. Duplicate scalar names retain their existing last-value precedence;
this does not change the separate strict identity or subscription-map readers.

Selection and deployment read `vars.VALIDATE_MODULE_CLIENT_IDS`, the
producer's flat canonical-root-to-client-GUID JSON map. Use the shared
producer validator, not another naming or parsing convention. Child and
nested child paths use their slash-delimited root entry; resource, pattern
and utility roots follow the same contract. Reject missing, malformed,
duplicate, case-colliding or reused bindings. Never fall back to
`VALIDATE_CLIENT_ID`, `AZURE_CREDENTIALS` or legacy OIDC exceptions.
Each matrix entry binds the root/client/tenant, original subscription pool
index/digest, native owning module path, selection seed and case index.
Revalidate them before authenticating rather than switching an already-selected
identity or target when configuration changes.

The tools-owned `bicep-module-identity` action exposes that same producer-backed
resolver to retained registry-local workflows. It reads the checked-out caller's
module path, the flat module-client map and the effective validation tenant,
then emits only `clientId`, `tenantId`, `moduleRoot` and `identityKey`. Validate
the complete input before emitting any output. It neither loads a native runtime
nor authenticates. Retained HCI preparation and consumer workflows use these
outputs for every initial and renewed sign-in, completion and recovery; the old
shared identity remains untouched but is not a fallback.

Subscription pool precedence is variables `VALIDATE_SUBSCRIPTION_IDS`, then
`TEST_SUBSCRIPTION_IDS`, then those secrets. Singleton subscription and tenant
prefer `VALIDATE_*` variables over secrets; the mapped tenant must be a GUID.
Management group prefers variables `VALIDATE_MANAGEMENT_GROUP_ID`, then
`ARM_MGMTGROUP_ID`, then those secrets. Malformed preferred values fail.
Forward the pool explicitly to workflow selection, then explicit
`SubscriptionId` and `TenantId` to native execution; shared phases must not
reselect their target from ambient CI pools.
Matrix preparation and deployment require integer package capability
`PrivateData.AvmCapabilities.BicepTestSubscriptionSelection = 1`. The adapter
calls public `Select-AvmTestSubscription` with the explicit caller repository,
module and exact example, the complete effective pool, seed and case index.
Native discovery resolves child ownership before exact reservation lookup;
never substitute the family identity root. Deploy and Complete target that
selected owning module, with the selected example rebased relative to it.
Dependency preparation uses the same owner path, and exact prerequisite maps
are therefore evaluated for the child without changing its family-root identity.
The adapter may form one id/name
record from the explicit singleton only when no pool is configured, leaving
validation and reservation enforcement to the native selector. It does not
parse, filter or shuffle pools itself. Validate every active selection before
resolving the compiler, and rerun the identical native selection before login.
Use public `Get-AvmModuleContext` to admit the selected owner for direct native
execution before compiler preparation or authentication. Read-only discovery is
not an execution-admission promise; unsupported owners never bypass the native
reserved-ancestor guard or silently retarget to a family root.
Non-General results fail before compiler or Azure dependency preparation and
authentication; they require the retained registry-local lifecycle.

Both initial and renewed `azure/login` calls use the same selected client,
tenant and subscription with `enable-AzPSSession: true`. Keep one mapped root
per job/execution context. Check the selected service principal, tenant,
subscription and cloud before Deploy, Complete and state-only recovery;
the package also guards CLI/PowerShell agreement. Deployment identities do
not replace unrelated publication credentials.

Before deployment authentication, require integer package capability
`PrivateData.AvmCapabilities.BicepRequiredResourceProviders = 1`. The native
Deploy/All runner alone discovers and validates repository-root
`.required-features.json` and `.required-resource-providers.json`, using the
exact module path rather than the identity map's canonical-root inheritance.
Feature prerequisites precede provider prerequisites, then token replacement,
validation and deployment, in the already selected tenant/subscription
context. The optional provider map contains namespace arrays, not feature
names or identities. Missing, empty and unrelated requirements do not issue
registration calls. WhatIf, Complete, cleanup and nondeployment workflow
paths never register. Registration persists after testing and does not grant
the test identity additional permissions. The marker does not qualify a
release containing the other required runtime and policy interfaces.

Keep `avm-validation` for selection/execution and `publish-approval` for tag
approval. One per-case lifecycle lock covers deployment, assertions, post hooks,
cleanup and cleanup-only recovery. Queue rather than cancel. The deployment
job alone receives full CI variables/secrets, including its pre-login isolation
input check. Retain generic `gci` and separate custom resource location from fixed
`WestEurope` metadata location. Renewal precedes Complete after either a
successful or failed Deploy. Native completion validates saved state, runs
the final terminal deployment's post hook once, and then cleans every attempt;
it must not mask the original deployment failure. KeepResources skips post
and cleanup. Unsafe, changed-source or interrupted-completion state must not
replay authored code. Cleanup-only recovery uses persisted state without
authored hooks, and cancellation prevents starting renewal, completion or
recovery. Artifacts contain only allowed
diagnostics and credential-free state; skipped or malformed executions are
not passing results.

Release jobs create only module Git tags for the existing ADO publication
path, never MCR publication. Retain upstream/main/manual guards, child-before-
parent ordering, same-target tag reuse, conflicting-tag failures and
reconciliation of uncertain pushes without mutation replay. Preview cannot
create or push tags.

Shared pending-release support compares each tracked compiled/versioned module,
including versioned children, against its own latest semantic-version source
tag across all version lines. A manual pending release includes publishable
`main.json` or `version.json` changes older than the latest main commit, but
not docs, metadata, authored source or test-only edits. A module without a
release tag is an initial release of its tracked compiled/versioned files;
do not substitute the target's parent, force unchanged modules or infer that
an ADO handoff tag proves MCR publication completed.
Validate complete history and each selected tag's commit ancestry; unavailable,
invalid or failed history/tag reads are errors, not empty successful selections.
Recheck independent child/parent baselines inside the existing module publication
lock, create changed children before parents, and retain tag version, reuse,
conflict and push-reconciliation semantics. Explicit before/after push discovery
and existing leaf defaults remain unchanged. The published runtime exposes pending discovery and tagging without adding
workflow events, authentication, deployment, publication activation or a
caller-facing mode/input surface. A tools workflow revision is not usable by
the registry until its matching runtime capability has been published.

`Set-AvmBicepReleaseTags -RequireChangelog` is an opt-in release precondition;
omitting the switch or passing false preserves existing caller defaults and
the `Set-AvmWorkflowReleaseTags` compatibility adapter.
Resolve current source baselines and calculate the complete child/parent tag
proposal once, then validate every proposed version before creating or pushing
any tag in that module's plan. Both pending and explicit-base releases use this
guard. Reuse the installed `Avm.Authoring` Bicep version/changelog parser,
not a second target-version calculation or a full compliance/test/deployment run.
Each planned module needs a regular exact-case readable UTF-8 `CHANGELOG.md`,
semantic release headings, exactly one section for its actual proposed version,
and one nonempty Changes section followed by one nonempty Breaking Changes
section. Missing, malformed, duplicate, unreadable or stale notes fail with the
module path and expected version; a guard failure leaves the plan's tags
untouched. Successful preflight executes those same proposals, retaining
same-target reuse and conflicting-tag/remote-reconciliation safeguards.
Changelog-only changes do not make a module publishable, and an empty release
plan does not require notes. The guard adds no package dependency, workflow
trigger, authentication, approval bypass or lock guarantee.

Publishing an executable candidate is not a package release, federation apply
or registry cutover. Moving deployment to tools changes `job_workflow_ref`
to the exact tools deployment workflow at the immutable caller pin; it only
affects authentication when the configured subject includes that claim.
Registry and Tools currently configure only `repository_owner_id`,
`repository_id`, and `context`; the latter expands to
`environment:avm-validation`. Add one distinctly named registry credential
per module using that exact subject, the existing issuer and audience, and
the existing federation API. Retain the staged workflow-bound and Tools
validation credentials without changing their subjects or resource names.
Do not change the GitHub subject configuration. New workflow restrictions
and flexible credentials are a separate follow-up; tools pin changes do not
require credential changes under the current three-claim contract.
Generic execution keeps its internal-fork controls and the PR entrypoint's
E2E-only label admission without adding a base-main restriction. The same registry
subject can authenticate
multiple module identities: workflow selection is not a federated per-module
isolation boundary. Never substitute the Tools validation credential for a
registry caller. Keep the old shared Bicep identity unchanged.

The scheduled main-only Bicep identity reconciliation can apply the additive
credentials after merge, so its merge/apply and subsequent registry cutover
require separate approval. Branch publication and review checks do not apply
the credentials or establish live login readiness.

The registry's existing `bicepconfig.json` selects
`docs/templates/avm-readme-v1.scriban` with `includeRoot=docs/templates`.
Remove only `documentation.template` after compatible-release and remaining-
consumer qualification to select the package default; preserve examples,
compiler settings and still-used Scriban files. Coupled workflow pin changes
edit module callers whose own files are main-push triggers, potentially
starting fleet validation. Registry merging/cutover needs an approved rollout
window. Do not retire registry platform-cleanup tests or native compatibility
coverage solely because workflow source checks pass.
Registry caller replacements use the tools-owned orchestration:
static PR checks need no label, and internal E2E checks require only
`PR: Run E2E Tests`;
ignored jobs exit before checkout, bootstrap or sign-in. The seeded matrix
retains the original subscription index and canonical GUID-based identity.
Main, preview and publish callers share the deployment implementation and the
reviewed isolation policy below. Publication retains its separate per-module
lock. Initial login and renewal
use OIDC with the selected subscription and tenant, without module-specific
client-secret exceptions or credentials in outputs. Avm.Authoring consumes
the caller's authenticated session; it does not sign in or renew credentials.
Registry caller replacement and live qualification require separate approval.

#### Deployment-test concurrency and contributor isolation contract

ARM scope type is not a contention domain. Management-group/tenant scope,
nested deployments and locally stored template expressions never independently
request serialization. Ownership inspection accepts inline templates and exact
lexical parent `variables('name')` object references, not a general ARM
expression evaluator. Matrix selection still compiles active tests and uses the
unchanged native subscription selector, reservation checks and identity binding.

An exact case-local `isolation.json` records the source review that establishes
isolation. It is not a generated certificate, a naming-only claim, or proof from
a checksum. Its review must cover the complete deployable source/dependency
closure, active branches, scripts, hooks, assertions, fixtures and cleanup:

```json
{
  "version": 1,
  "evidence": {
    "resources": "Identify every owned resource/group and nested deployment, and explain its run/case-derived identity.",
    "cleanup": "Explain why recorded Create operations and all hook/service cleanup affect only owned resources.",
    "sharedState": "Identify all shared reads and mutations, including settings and imported fixtures; explain why no undeclared shared target is mutated.",
    "identity": "Explain init/idem identity reuse, InPlace identity preservation and Fresh attempt ownership."
  }
}
```

Contributors must replace those example descriptions with concrete source
references and meaningful behavioral tests under the owning module. Updating
the sources requires re-reviewing the contract in the same change; four strings
are a review declaration, not an automated semantic verifier. Unique root
deployment names alone never qualify. Inspect fixed resource/assignment names,
cross-scope resources, auxiliary groups, deployment scripts and provider-managed
infrastructure. ARM `Create` may update an existing resource: operation history
alone does not prove ownership. Existing shared fixtures must stay read-only.

A declaration alone never unlocks a case. Selection requires a qualified native
package exposing `RequireResourceIsolation` and checks the compiled ownership
boundary. The first supported mutable boundary is flattened
`Microsoft.Storage/storageAccounts` resources and their children inside a fresh
native-created resource group. Native creation refuses a pre-existing group,
verifies its exact ID/run tag, and rechecks ownership before every submission,
including InPlace. Nested deployments must stay in that group and have
inspectable templates. Resource scope escapes, test-created groups, unproved
provider types/service-managed infrastructure, deployment scripts, post hooks
and required feature/provider registrations retain diagnostic fallback.
Assertions still require source review as read-only; arbitrary authored code is
not sandboxed. Empty templates without nested mutations can qualify at any
scope; scope type alone is not an ownership or contention finding.

The workflow passes `RequireResourceIsolation` on every reviewed deployment.
The native package repeats structural checks before Azure access and persists
the boundary in cleanup-state schema 2. Older recovery packages reject that
version instead of silently discarding the guard; ordinary states remain
schema 1. Operation traversal checks every Create target before following a
nested deployment or accepting a deletion target. Recovery and cleanup verify
the persisted boundary and ownership tags; foreign IDs and unsupported provider
cleanup are refused. Known owned resources may still be cleaned after an
out-of-bound operation is rejected, but uncertain parent-group cleanup remains
pending. This initial boundary does not qualify arbitrary Azure providers.

Reviewed cases run concurrently by default within or across subscriptions.
The workflow overrides the effective `namePrefix` token with
`<prefix>#_avmE2eSuffix_#`, using the native ten-hex suffix from the per-case
32-hex naming ID. Prefixes are lowercase alphanumeric, one to three characters
(`gci` by default); provider-specific final-name bounds still need module tests.
Root deployment/group naming retains the full native ID. Repeated cases/runs
get distinct contexts, InPlace preserves the exact context, and Fresh creates
another owned context whose resources remain tracked until final cleanup.
Authored sequential init/idem deployments retain their existing shared
within-case identity; tools never rewrites or strips them.

Before login, the native CI alias resolver checks effective variables/secrets
against compiled test parameters. Reviewed execution rejects any matching CI
parameter override, implicit CI Key Vault parameter lookup or custom local
token other than the workflow-controlled prefix. These can invalidate reviewed
default naming or fixture assumptions. Unrelated CI entries are harmless.
Cases needing such overrides retain fallback until their effective-input
ownership can be established; do not silently disable inputs or assume safety.
Explicit native scope and location inputs remain supported.

An actual shared mutation adds one optional `sharedTarget` containing the
absolute ARM resource/singleton-setting ID. Only `#_subscriptionId_#` is
substituted, from the selected subscription; fixed cross-subscription IDs remain
fixed. The lock key hashes cloud, canonical tenant and case-insensitive target
ID, not module, case, allocation index or run. Different modules and competing
runs in the same caller repository using the same target therefore serialize
through final cleanup/recovery. A target declaration does not authorize a
mutation outside the enforced native boundary. Unsupported shared mutations
still retain fallback. Every user of that target must declare the same
identity, including parent/child settings that contend. Multiple independent
shared targets, non-ARM settings, dynamic/unidentifiable targets and cross-repo
coordination are not supported by this one-lock workflow contract: retain
fallback or use a separately reviewed external lifecycle coordinator. Do not
invent module names as shared-target IDs.

Missing isolation evidence emits a visible diagnostic; malformed declarations
fail. Unverified cases retain the legacy inner module/subscription lock, with
the additional outer module-wide fallback retained among unverified cases when discovery
finds mutable tenant/management-group templates or uninspectable external
templates. Empty scope templates and inspectable lexical variable indirection
do not independently require that broader fallback. These are migration-only
compatibility protections for unestablished ownership, not scope-based proof
of contention. Reviewed cases never inherit those fallback locks.

A repository-wide fallback would broaden serialization for unrelated modules
and subscriptions without establishing mixed-population protection, so it is
not used. Legacy fallback keys, verified-case keys and declared shared-target
keys are distinct: they do not coordinate undeclared overlap across modules,
between old/new workflow revisions, or between reviewed and unverified cases.
The shared-target guarantee covers competing executions that declare the same
target under this contract, not every possible legacy user of that target.
Migration must prove there is no overlap or migrate/coordinate every actual
target user before enabling parallel execution. Recheck mode and lock identity
before authentication.
Ignored cases require neither isolation evidence nor subscription/compiler
preparation. `sharedScope=false` remains only a compatibility output; there is
no shared-scope outer lock or automatic module/subscription lock for reviewed
cases. Keeping both legacy levels for unverified cases preserves their existing
same-subscription coordination when another run has a different case matrix.

All three deployment matrices cap active legs at four independently of target
locking, with fail-fast disabled. This bounds each module invocation, not total
fleet/API pressure across runs or modules. Existing publication locks, pool
routing, reserved/HCI protections and ordinary cleanup remain unchanged.
The job-level queue never cancels an older lifecycle. GitHub releases the lock
when the job ends even after uncertain cleanup; recover pending state under the
same target lock before reusing shared infrastructure. Reviewed shared-target
execution rejects `removeDeployment=false` before login: `KeepResources` is not
safe shared-target handoff. Locks are repository-local, not an Azure lease.

Rollout requires a qualified native package supporting `RequireResourceIsolation`,
naming tokens, retry identity and boundary-enforced schema-2 cleanup/recovery, a coordinated immutable tools workflow
pin, module-owned isolation evidence/tests, and a separately approved validation
window. Allow existing campaigns/cleanup to finish before mixing lock revisions;
never cancel or dispatch campaigns as part of this migration. In particular,
subscription-scope ACA sources need review of auxiliary/service-created groups,
certificate scripts, fixed assignment names and effective input overrides; the
tooling change does not activate any registry case: ACA defaults/max remain
fallback, including at the existing `ba9af85f` tools pin. Fresh test-created RG
absence and provider-created managed-environment infrastructure are not proved
by those sources or by recursive Create history. A compatible package/pin does
not supply that missing proof automatically. Local behavioral fixtures qualify
selection/identity/cleanup contracts, not live ARM behavior or fleet capacity.

Package-owned PSRule parameter defaults are for static expansion only.
In particular, the synthetic `builtInServicePrincipalObjectId` default must
never populate native deployment parameters.

### Files inside the user's home

The module's own state lives under per-user folders per §7. It never drops dotfiles directly in `$HOME` (no `~/.avmrc`, no `~/.avm/`). The `$HOME/.config/avm`, `$HOME/.cache/avm`, etc. layout on Linux is the only Unix-style hidden state.

---

## 9. Subprocess invocation

### Rules

- Use the call operator `&` with an **array** of args. Never string-concatenate args.

  ```powershell
  $args = @('plan', '-out', $planFile, '-input=false', $modulePath)
  & $terraformExe @args
  if ($LASTEXITCODE -ne 0) { throw "terraform plan failed (exit $LASTEXITCODE)" }
  ```

- Always pass the **resolved absolute path** to the binary (from the tool resolver, §10). Never rely on `PATH` for managed tools.
- Quote nothing. The array form bypasses the shell entirely — no quoting bugs possible.
- Always check `$LASTEXITCODE` after every shell-out. The standard helper `Invoke-AvmProcess` (in `Private/`) wraps the pattern, captures stdout/stderr, and throws on non-zero unless `-IgnoreExitCode` is set.
- Long-running calls pass `-StreamOutput`, which emits both child streams on the Information stream while retaining their captured values on the process result.
- Stdout and stderr captured separately via `Start-Process -RedirectStandardOutput/-RedirectStandardError` so they can be re-emitted on their respective streams without merging.
- Long-running processes emit `Write-Progress` every 5 seconds; cancellable via `Ctrl+C`, which sends `SIGINT`/`Ctrl+Break` to the child and waits up to 10 seconds before `SIGKILL`/`TerminateProcess`.

### Argument escaping is not the answer

If you ever feel the need to quote args, you're invoking through the shell. Stop and use the array form.

### TTY detection

Anything that draws progress bars or uses ANSI escapes guards on `-not [Console]::IsOutputRedirected -and -not [Console]::IsErrorRedirected`. CI is never a TTY; plain text only.

---

## 10. Tool resolver and cache layout

This section defines the concrete OS-aware paths and file conventions.

### `avm.pins.jsonc`

Schema enforced by `Test-AvmPins`:

```powershell
@{
    schemaVersion = 1
    tools = @(
        @{
            name        = 'terraform'                  # lowercase, kebab-case
            version     = '1.9.5'                       # semver, no leading 'v'
            urlTemplate = 'https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{os}_{arch}.zip'
            archive     = 'zip'                         # zip|tar.gz|raw
            entrypoint  = 'terraform'                   # binary basename, no extension
            sha256 = @{
                'windows-amd64' = '...'
                'windows-arm64' = '...'
                'linux-amd64'   = '...'
                'linux-arm64'   = '...'
                'darwin-amd64'  = '...'
                'darwin-arm64'  = '...'
            }
        }
    )
    powerShellModules = @{
        Pester = @{ version = '5.7.1'; sha256 = '...' }
    }
}
```

- All URLs are `https://`. A non-`https://` URL fails the schema check.
- The `{os}` placeholder resolves to `windows`, `linux`, or `darwin`. The `{arch}` placeholder resolves to `amd64` or `arm64`.
- The `entrypoint` value is always lowercase. On Windows the resolver appends `.exe` only when computing the final path.
- `powerShellModules` contains exact stable versions, Gallery package SHA256s,
  and optional `dependencies` naming other pinned modules. The shared resolver
  downloads their official Gallery ZIPs and uses `<Name>.psd1` as the entrypoint.
  Pester must be at least 5.5.0. Required module dependencies must match the
  configured names, versions and resolved paths before use.
  Select exactly one exact-name module from `Import-Module -PassThru` output;
  `ScriptsToProcess` initializer metadata is not the requested module.
  Initializer failures still fail the import, and selected version, path and
  dependency checks remain mandatory.
- PowerShell module ZIP validation reads every entry and requires one root
  manifest plus NuGet metadata identifying the exact pinned package/version.
  A locally detected `InvalidDataException` while reading/extracting the ZIP
  permits exactly one retry in a new staging directory. Apply this to each
  pinned dependency as well as the requested module. Never retry checksum,
  transport, permission, metadata or import failures as archive corruption.
  A failed replacement must not remove the existing verified package before
  validation; keep the lock, checksum/host/offline controls and atomic per-package
  publication. Do not replace stable pins with dynamic prerelease resolution.
- Both composite commands resolve and import-check all applicable prerequisites
  before metadata/step 1, after the module-upgrade and context/clean-tree guards.
  `pr-check -ExcludeSteps` removes prerequisites used only by excluded steps,
  retaining those shared with any remaining step. Default prerequisite sets and
  resolution order are unchanged.
  Standalone metadata, Bicep Pester, YAML and PSRule entrypoints share the same
  mechanism. Build prerequisites supply that same Pester pin, and all test
  runners, including isolated shards, import it through the shared resolver.
  Reject a different already-loaded module version with fresh-session guidance
  before composite step 1. Pester must also have the configured module path:
  reject even the same version from another path before importing a second
  engine, and require a fresh PowerShell session.

`PrivateData.AvmCapabilities.BicepRequiredResourceProviders = 1` identifies the
native prerequisite contract above.
`PrivateData.AvmCapabilities.PowerShellModuleArchiveRecovery = 1` identifies
the managed module archive-recovery contract. Consumers require exact integer
markers on the selected installed Avm.Authoring package, not on a separately
checked-out workflow source tree. Existing `Get-AvmTool -Path` inspection and
`Install-AvmTool -Path` installation are the dependency adapter boundary; no
second provider parser, ZIP recovery implementation or wrapper-only public API
is permitted. Capabilities are not evidence that a combined runtime/workflow
package has been released or qualified.

### Repository tool versions

`.avm/tool-version-overrides.json` is an optional, flat JSON object mapping exact
known tool/module names to version strings. It cannot add tools, URLs, hashes,
entrypoints or dependency definitions. Reject malformed files, duplicate or
case-colliding names, ranges, invalid versions and linked files/directories.
Terraform and standalone modules use their authoritative root. A recognized
Bicep monorepo uses only its root file, including module-targeted commands;
nested module files are ignored. Resolve this context before staging or
parallel work, and never cache effective pins across repositories.

Only explicitly named entries bypass pinned checksum verification, including
same-version overrides. Untouched dependencies retain packaged versions and
hashes. Use the trusted packaged download template, normal platform rules,
TLS, mirror and offline controls. Emit a tools warning with the source file,
packaged/selected version and disabled-verification notice before use, including
cache hits. Tool and doctor results retain this provenance.

This user-directed checksum exception requires recorded SFI sign-off before
merge/release. Repository file changes select executable dependencies and must
be reviewed before running privileged commands.

### Cache layout

```text
<Data>/tools/<tool>/<version>/
    <entrypoint>[.exe]        # binary or PowerShell module manifest
    .verified                # zero-byte marker — present iff SHA matched and unpack succeeded
    .meta.json               # source, version, platform, hash and verification state
```

- Atomic install: extract to `<Data>/tools/<tool>/.staging/<short-uuid>/`, verify SHA, then `Move-Item` (rename) to `<Data>/tools/<tool>/<version>/`. On rename failure (someone else got there first), discard the staging dir and use whoever won the race.
- Cross-process lock: file lock on `<Data>/tools/<tool>/.lock` while installing; lock held via `[System.IO.File]::Open(..., FileMode.OpenOrCreate, FileAccess.Write, FileShare.None)`.
- Binary cache hits require the entrypoint and `.verified` marker. PowerShell
  packages also require matching cache metadata and the configured package hash.
- Overrides use `<Data>/tools/<tool>/.overrides/<version>/`, `.unverified` and
  matching unverified metadata. Never accept or overwrite a verified default
  entry with an override, or accept a loaded override as an installed default.
  Switching away from a loaded unverified PowerShell package requires a fresh
  process, avoiding reuse of its already loaded code.
- `avm tool install --force` stages the replacement before removing the old
  entry under the installation lock. Failed downloads leave the old entry intact.

### Lookup order on every invocation

1. **Cache** — use a complete verified entry, or the separate unverified entry for an explicit repository override.
1. **Installed PowerShell module** — accept the exact selected version discoverable on `PSModulePath`, outside managed caches, with a matching manifest. Do not select arbitrary already loaded modules or change user/system module installations.
1. **Binary PATH (opt-in)** — only when the caller passes `-AllowPathFallback` (the engines' opt-in switch; off by default). `Get-Command <entrypoint>` → if found and it reports the locked version, use it. If found but the version is wrong, warn once and fall through to install. The gauntlet verbs do **not** enable this by default, so PATH is normally ignored in favour of the pinned managed tool.
1. **Auto-install (default)** — a cache miss installs the selected version through the same atomic, locked downloader as `avm tool install`, verifying its SHA256 unless explicitly overridden. A concise progress message is emitted on first use. Set `AVM_NO_AUTO_INSTALL=1` (or pass `-NoAutoInstall`) to disable implicit installation; a miss fails with `avm tool install <tool>` guidance. `AVM_OFFLINE=1` and `AVM_MIRROR` still apply. Explicit module installation also acquires its pinned dependencies in dependency order.

`avm tool list` mirrors this order: `installed` for a cache hit,
`installed-on-module-path` for an exact installed module, `not-installed` when
a miss would auto-install, `auto-install-disabled` when it would fail, and
`installed-on-path` / `outdated-on-path` only with `-AllowPathFallback`.

### Offline mode

- `AVM_OFFLINE=1` → resolver refuses any HTTP traffic. Cache hit succeeds; cache miss fails fast with a clear message naming the missing tool.
- `AVM_MIRROR=https://internal.example.com/avm-mirror` → every `urlTemplate` is rewritten before download. The mirror's scheme, authority, and path prefix are preserved; the source URL's path-and-query is appended verbatim. With the example above, `https://releases.hashicorp.com/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip` is fetched from `https://internal.example.com/avm-mirror/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip`. The mirror itself MUST be `https://`; an `http://` mirror is refused with `AvmConfigurationException` so a misconfigured proxy cannot silently downgrade TLS. `file://` source URLs (test fixtures) are never rewritten.
- `AVM_NETWORK_RETRY_MAX_ATTEMPTS=<1-10>` → overrides the attempt limit for every retried network read (default 4 from `Resources/network.json`). `1` disables retry. Advisory lookups such as the module update check never exceed their smaller budget.

---

## 11. Output, logging, and streams

### Stream discipline

| Stream             | When                                                          |
| ------------------ | ------------------------------------------------------------- |
| `Write-Verbose`    | Useful when debugging; off by default; gated by `-Verbose`    |
| `Write-Information` | Human progress narration; on by default                       |
| `Write-Warning`    | User should know but it didn't stop us                        |
| `Write-Error`      | Recoverable per-item failure inside a loop; caller decides    |
| `throw`            | Unrecoverable, terminating                                    |
| `Write-Host`       | TTY-only banners; never for data                              |
| Pipeline output    | Structured `pscustomobject`s; the **only** data contract       |

`-Verbose`, `-Debug`, and `-InformationAction` work via standard `[CmdletBinding()]`.
Direct verbs emit routine progress narration by default. Composition verbs such
as `avm pre-commit` and `avm pr-check` emit their step start/result lines but
suppress nested `Info` and `Pass` narration. `-Verbose`, `AVM_VERBOSE=1`, and
GitHub Actions runner debug mode restore all nested narration. Warnings and
errors are never suppressed.

Terraform lint presents every finding at or above its failure threshold through
the shared error logger when lint completes, before subsequent composition
steps. This produces source-linked GitHub error annotations and visible local
error diagnostics even when the underlying issue is a blocking warning.
Preserve the original issue severity, threshold/status semantics and complete
scope collection. Below-threshold canonical AVM notices remain advisory
warnings. Final dispatcher and composition rendering must not repeat already
presented findings; every finding remains in the structured result.

Internal Terraform source, module-cache, lint-configuration and policy staging
copies suppress filesystem-provider progress bars per operation without changing
the caller's progress preference. Transform dependency copies follow the same
rule; copy and inspection-cache diagnostics remain available through verbose
logging. Copy errors retain their existing terminating behavior.

Sensitive-output consumers can use `Invoke-AvmProcess -StreamOutput` with
`OnStdOutLine` and `OnStdErrLine` callbacks to own both streams' incremental
rendering. A handled stream is not echoed or replayed unfiltered on failure.
Captured output and exception data remain private inputs to the caller, which
must sanitize diagnostics before publishing them. A failed callback stops the
child process and propagates the error.

Bicep identity sync displays Terraform's human-readable saved plan only after
the ownership and migration guards accept it, then streams per-resource apply
progress. `Protect-RepositorySyncLogText` redacts configured credentials from
both inherited and child-specific environments, including multiline values.
Ordinary names and client IDs remain visible; Terraform sensitive annotations
remain intact. Machine-readable plan/output JSON and raw state stay private,
including error and timeout paths. Streaming is opt-in so existing buffered
repository-sync callers remain compatible with the published module.

During Pester runs, the build harness temporarily clears `GITHUB_ACTIONS` and
`GITHUB_STEP_SUMMARY`, and pauses workflow-command parsing while tests
deliberately exercise GitHub
annotations. Their diagnostics remain in the job log, but do not appear as
real run annotations or write to the run's step summary. Normal commands
retain native GitHub annotations.

Warnings and errors that carry a file and line position preserve it as
`message (path, line N[, column N])` in ordinary terminal output. GitHub Actions
keeps using native workflow annotations without duplicating the position in
the message.

The `avm` dispatcher renders every result carrying `Status`, including each
composition step and nested issue, before returning or throwing. When
`GITHUB_ACTIONS` is set, the same rendering is appended to
`GITHUB_STEP_SUMMARY`.

### `--json` mode

When a public verb is invoked with `-Json` (or via the dispatcher with `--json`):

- Stdout contains **only** a single JSON document (one object or one array).
- All human-readable narration moves to the `Write-Information` stream and is suppressed from stdout.
- All errors emit a JSON object on stderr: `{ "error": { "code": "...", "message": "...", "details": {} } }`.
- Exit code is `0` on success, `1` on user error, `2` on internal/unexpected error, `>=10` reserved for verb-specific codes.

### Colour and ANSI

- Honour [NO_COLOR](https://no-color.org): if `$env:NO_COLOR` is set (any value), no ANSI escapes.
- Honour `$env:CLICOLOR_FORCE=1` to force colour even when stdout is not a TTY.
- Default: colour on in GitHub Actions and when stdout is a TTY, provided
  `NO_COLOR` is unset. Workflow command annotations remain free of ANSI escapes.

### Time and locale

- All timestamps in logs and JSON are UTC ISO-8601 (`2026-05-18T13:42:05Z`). No local time, no locale-formatted dates.
- All log messages are in `en-US`. Localised strings (if added later) live under `en-US/Avm.Authoring.psd1` and load via `Import-LocalizedData`.

---

## 12. Module manifest rules (post-incident)

Hard rules learned from the 2026-05 casing incident:

1. The on-disk `.psd1` file's basename **is** the package id on PSGallery. `Publish-PSResource` ignores the manifest `Name` for this purpose.
2. The on-disk module folder, the on-disk `.psd1` file, the on-disk `.psm1` file, the manifest `Name`, and the manifest `RootModule` value must all match each other **case-sensitively**.
3. NTFS preserves the existing casing across delete-and-recreate of a path. Renaming via "delete then recreate with new casing" silently does nothing on Windows.
4. `Test-Path`, `Test-ModuleManifest.Name`, and `Resolve-Path` are all case-insensitive on NTFS and APFS. None of them can be used to assert casing.

The mandatory pre-publish check `Test-AvmModuleLayout`:

- Resolves the module folder via `Split-Path -Leaf` and asserts `-ceq` against the expected name.
- Lists the folder via `Get-ChildItem` and asserts the `.psd1` and `.psm1` files are present **with the exact expected casing** via `Where-Object { $_.Name -ceq $expected }`.
- Parses the manifest and asserts `Name -ceq $expected` and `RootModule -ceq "$expected.psm1"`.
- Runs while staging in the `build` task. The GitHub-owned `scripts/Publish-AvmAuthoring.ps1` repeats the equivalent exact-casing checks against the extracted signed release asset before `Publish-PSResource`.
- Has its own Pester test that builds a fake module folder with a deliberately mis-cased file and asserts the check throws.

---

## 13. Public API surface

### Two equivalent styles

| Style                | Example                          | Implementation                                                                 |
| -------------------- | -------------------------------- | ------------------------------------------------------------------------------ |
| Verb dispatcher      | `avm pre-commit`                 | Single `avm` function in `Public/` routes to the right cmdlet                  |
| Approved-verb cmdlet | `Invoke-AvmPreCommit`            | Direct call to the implementation function                                     |

Both call the same implementation. The dispatcher is generated from a single verb registry (`Private/Get-AvmVerbRegistry.ps1`) so the two surfaces stay in lock-step.

### Cmdlet rules

- `[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]` on every cmdlet that mutates state. Read-only cmdlets omit `SupportsShouldProcess`.
- `[OutputType(...)]` on every public function. Helps tab completion and IntelliSense.
- Mandatory parameters declared `[Parameter(Mandatory)]`; defaults provided where sensible (`$Module = $PWD.Path`).
- Pipeline-friendly: `ValueFromPipeline` and `ValueFromPipelineByPropertyName` declared where it makes sense; `begin`/`process`/`end` blocks used correctly.
- Comment-based help on every public function, with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.OUTPUTS`. Linted via PSScriptAnalyzer.

### Stability contract

- After the first stable release (`1.0.0`):
  - Removing or renaming a public cmdlet requires a major version bump.
  - Removing a parameter requires a major version bump.
  - Adding a parameter is a minor bump.
  - Changing default parameter values is a minor bump and must be called out in `CHANGELOG.md`.
  - Bugfixes are patch bumps.

---

## 14. Error handling

- Every public function: `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` in `begin`.
- Terminating errors use `throw [<SpecificException>]::new(<message>, <innerException>)`. Generic `throw "string"` is reserved for prototype code and is flagged by PSScriptAnalyzer custom rule `AvmAvoidStringThrow`.
- A small set of exception types lives in `Private/Exceptions/`:
  - `AvmConfigurationException` (`AVM1001`) — bad config, missing required env var.
  - `AvmToolException` (`AVM1010`) — tool resolver / install / SHA mismatch.
  - `AvmProcessException` (`AVM1020`) — subprocess exited non-zero; includes captured stdout / stderr.
  - `AvmContextException` (`AVM1030`) — repo context resolver couldn't classify the path.
  - `AvmCommandException` (`AVM1040`) — a composite verb reported a failing status.
  - `AvmModuleVersionException` (`AVM1050`) — the installed module is behind the published release.
  - `AvmManagedFilesVersionException` (`AVM1060`) — a new major managed-files release supersedes the repo's pin.
  - `AvmException` (`AVM1070`) — Azure feature/provider registration, approval, or readiness failed.
- Exit codes from the dispatcher:
  - `0` — success.
  - `1` — user error (bad args, bad config, expected condition).
  - `2` — internal / unexpected error.
  - `10` — the installed module is superseded and must be upgraded.
  - `11` — the managed-files pin is superseded by a major release.
  - `12–19` — reserved for the `tool` verb tree.
  - `20–29` — reserved for the `test` verb tree.
  - `30–39` — reserved for `publish` / `release`.
- Exceptions carrying an `ExitCode` property set it themselves; the dispatcher
  honours it rather than mapping the type to a code.

---

## 15. Concurrency

Assume the user runs multiple `avm` invocations in parallel against different repos on the same machine:

- The tool cache is safe to share across processes (cross-process lock per §10).
- Per-repo state under `.avm/` is **not** safe to share — assume one CLI invocation per repo at a time. Document this; do not engineer locks for it.
- No code reads or writes `$env:` variables after `begin` runs (env is captured once per invocation).
- Avoid module-level mutable state. Every cmdlet is reentrant and pure with respect to its parameters and resolved environment.

---

## 16. Networking

- TLS 1.2 minimum, prefer 1.3. Set explicitly at module load:

  ```powershell
  [System.Net.ServicePointManager]::SecurityProtocol =
      [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
  ```

- Honour proxy env vars: `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` (Invoke-WebRequest does this natively; helper wraps it).
- All `Invoke-WebRequest` / `Invoke-RestMethod` calls go through `Invoke-AvmHttp` in `Private/` which:
  - Sets a `User-Agent: Avm.Authoring/<version> (<os>/<arch>)` header.
  - Times out after 60 seconds by default (overridable).
  - Retries transient failures (HTTP 408, 429 and 5xx, timeouts and connection resets) through `Invoke-AvmRetry`, using capped exponential backoff with jitter and honouring `Retry-After`. Limits live in `src/Avm.Authoring/Resources/network.json`; `AVM_NETWORK_RETRY_MAX_ATTEMPTS` (1–10) overrides the attempt count.
  - Verifies the certificate chain (no `-SkipCertificateCheck` — ever).
- Download SHA256 verification is non-negotiable; mismatch throws `AvmToolException` with both expected and actual hashes in the message.

Repository-sync team-existence discovery explicitly opts into HTTP 500, 502,
503 and 504 retries through `Get-GitHubTransientRetryPatterns -ReadOnly`.
Use this opt-in only for known read-only requests, never writes or command
sequences containing writes: a server error does not prove a write failed.
The shared GitHub CLI wrapper's default patterns, retry budgets, incremental
delays and failure handling remain unchanged. Deterministic 404 and
authentication/authorization failures do not gain retries.

---

## 17. Security

This section is the implementation-level expression of the **Security stance** preamble at the top of this spec. Read that first; the bullets below are how it manifests in code, configuration, and the build pipeline.

### Secrets

- No secret ever appears in source, in default config, in test fixtures, in error messages, or in telemetry.
- API keys, tokens, and similar are accepted via `[SecureString]` parameters or read with `Read-Host -AsSecureString`. Plain-text parameter form is documented as insecure and labelled `[Obsolete]` once a `SecureString` overload exists.
- The publish script (`scripts/Publish-AvmAuthoring.ps1`, owned by the GitHub release workflow) accepts the API key as `[SecureString]` only and converts it to plain text only at the `Publish-PSResource` boundary.
- Long-lived secrets (e.g. `POWERSHELL_GALLERY_API_KEY`) live in a protected GitHub Environment with required reviewers (or a repository secret consumed by an environment-gated job), never in repo / org variables, never echoed by any `run:` step (no `echo`, no `Write-Host`, no `Write-Output`). Workflows that consume them must declare `environment: <name>` so the approval gate fires before the job touches the secret.

### Subprocess invocation

- Process exec uses argv arrays only (section 9). No `cmd /c`, no `bash -c`, no `Invoke-Expression` on user-supplied data, no string-concatenated command lines anywhere.
- The CLI never runs `git config --global` on the user's behalf without `-Confirm`.

### Workflow / GitHub Actions hardening

- Every external `uses:` reference in `.github/workflows/*.yml` is pinned to a 40-character commit SHA, with the human-readable version as a trailing `# vX.Y.Z` comment. Floating tag references (`@v5`, `@main`, branch refs) are rejected at PR review. Same-repository reusable workflows use local `./.github/workflows/` paths, which resolve at the caller's commit. Rationale: a single tag-repoint on a compromised maintainer account would deliver attacker-controlled code into every CI run on the next push, and that code runs with `GITHUB_TOKEN`, `secrets.*`, OIDC mint rights, and full write access to the working tree. SHA pinning closes that vector at the cost of needing a maintenance loop for security fixes; that loop is Dependabot.
- `.github/dependabot.yml` enables the `github-actions` ecosystem on a weekly cadence, batches minor/patch bumps to reduce noise, and keeps major bumps as individual PRs so they get individual review.
- Every workflow declares an explicit top-level `permissions:` block. Default is `permissions: contents: read`. Write scopes (`contents: write`, `packages: write`, `id-token: write`, etc.) are added job-by-job with an inline comment justifying why.
- `actions/checkout` is always called with `persist-credentials: false` outside the release pipeline so the cloned repo's `.git/config` doesn't carry a token usable by any subsequent step or any subprocess that reads from the working tree.

### Tool binary supply chain

- Default binary and PowerShell package downloads are SHA256-verified against `Resources/avm.pins.jsonc` (section 10). A mismatch throws `AvmToolException` with both hashes. Only the explicit repository version-override exception may bypass the pinned hash for named tools, using a separate unverified cache and visible warning.
- `scripts/Update-AvmPins.ps1` is the only sanctioned path to rotate a hash; the PR that lands the rotation must record what was updated and which upstream release notes were reviewed.
- The repo bundles no precompiled binaries. Everything is fetched at first use and cached under the user's standard cache root (section 7).

### Test identity naming and replacement

- Terraform test identities use `id-test-terraform-` plus the lowercase repository
  name without its leading `terraform-`, replacing the known Azure-reserved
  `windows` substring with `w5s`; the owner is excluded. Reject normalized
  Terraform-name collisions across the complete installed repository inventory
  before filtering, and recheck it in workers with `windows` or `w5s` names.
  An incomplete or unavailable inventory must not bypass this check. Bicep test
  identities use `id-test-bicep-` plus the complete canonical root path with
  slashes replaced by hyphens, without the Terraform reserved-word substitution.
  Neither convention hashes or truncates names; no other words are abbreviated.
  Preserve the 90-character repository identity bound and
  68-character canonical Bicep path bound; reject Bicep flattening collisions
  before provisioning and validate complete federated credential names against
  Azure's 120-character maximum.
- Saved-plan guards may permit naming replacement only from the exact known
  legacy name to the computed current name for the same repository/module and
  tenant. Verify before/after resource identity, old dedicated client/principal,
  immutable repository/workflow federation, provider context and state-owned
  membership edges. A matching name alone is not ownership evidence. Retained
  federation and memberships must transition to the new identity; deletion of
  unrelated identities, shared groups, foreign principals, imported/moved
  identities or widened trust remains forbidden.
- Bicep mapping rebinding requires a trusted current-run/current-attempt
  job-local record produced from the verified saved plan and validated applied
  outputs. Bind it to the Tools repository ID, workflow ref and commit; accept
  only the verified old client or the already-published new client for each
  existing module. Preserve the other execution values except for the separately
  guarded subscription-tag updates below; preserve drift/readback
  checks and no-write-retry rule. No receipt is emitted for a plan-only run or
  failed apply/output validation. Lost evidence or partial migration requires
  separately approved recovery, never synthesized ownership or a general
  rebinding override.
- This exception requires recorded SFI sign-off before merge. It does not
  authorize live execution, change conditional Owner permissions, rename
  backend/controller/shared identities, or cut over Bicep validation consumers
  or their OIDC subject template.

### Reserved test subscription propagation

- The complete BAMI inventory remains 28 unique `{name,id}` objects with an
  optional lowercase `tag` field. A tag is a case-sensitive string of at most
  64 characters matching `\A[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*\z`. Omission means
  `General`; explicit null, malformed or miscased tags are errors. Preserve
  existing GUID, name, duplicate, Admin and Persistent protections and optional
  tag absence in historical source artifacts.
- Bicep receives the complete ordered tagged inventory in
  `VALIDATE_SUBSCRIPTION_IDS`, with the matching `VALIDATE_*` identity bundle.
  Terraform Actions/Dependabot publication and ordinary selection use only
  `General` entries, including untagged entries, with the historical `{name,id}`
  consumer shape. Filter before defaults, shuffling and round-robin assignment.
  A missing General pool fails before Terraform publication or deployment;
  explicit workflow overrides must belong to the filtered pool. Standalone Tools
  authoring CI reuses the repository-sync Terraform executor:
  `TEST_BAMI_CONTROLLER_CLIENT_ID`, `TEST_BAMI_TENANT_ID`, and
  `TEST_BAMI_ADMIN_SUBSCRIPTION_ID` from the `avm` environment supply both process
  `ARM_CLIENT_ID`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` and `azure/login`.
  Require OIDC without CLI or managed-identity fallback. Both Terraform fixtures
  on all three CI operating systems retain real authenticated plan/show and
  positive Conftest policy evaluation; no module apply is performed.
  Do not substitute a test-pool subscription, backend identity, Bicep executor
  or generated module identity. This reuse does not enroll Tools into module
  sync or change module repository `ARM_*` Secrets.
- Existing Bicep pool Variables may change only tag metadata on the same ordered
  subscription IDs and exact names, with a complete unchanged execution identity
  bundle. Validate both pools and reject additions, removals, renames, reordering,
  retargeting and malformed fields. An untagged historical source cannot erase
  an existing non-General reservation. Preserve existing bytes when effective
  tags are unchanged. Plans and applies retain snapshot freshness, pre-write,
  complete readback and final verification; no write retry or rollback is added.
- Deploy compatible Tools and registry consumers before publishing a new tagged
  source bundle. Earlier Tools rejects the additional field. No new pool or
  rollout variable is introduced, and protected legacy settings remain untouched.
  This isolates scheduling and defaults; it does not revoke Azure permissions.

### Repository-sync state-lock recovery

- Ordinary remote Terraform sync checks the selected state blob before each
  native plan or verified saved-plan apply, including plan-only runs. A missing
  or unlocked blob needs no release. Break a held lease at most once and verify
  release before starting Terraform. Failed or interrupted native commands are
  not replayed; never disable locking or rewrite/import state. Local bootstrap
  and Bicep sync do not opt in.
- Use GitHub Actions job concurrency keyed by the canonical repository state ID,
  independent of branch and provider prefix, with `cancel-in-progress: false`.
  Retain workflow-wide serialization; do not implement custom run/job polling
  or require an additional Actions read token. Permit any Tools branch in the
  Terraform Sync workflow for the selected repository. Check the initialized
  default-workspace backend against the exact selected key and all configured
  tenant/subscription/client/account/container values.
  CLI recovery authenticates only as the state identity;
  native Terraform and BAMI providers retain explicit OIDC and disabled CLI
  fallback.
- Inspect blob existence and lease properties, never resource state contents or
  Terraform lock metadata. Use Azure's ETag-conditional lease break on the exact
  blob. Failed or uncertain release stops without fallback or retry.
  Preserve original native errors/exit codes and redact credentials.
- Unknown-owner recovery is an explicit risk-accepted exception, not verified
  abandonment. Timestamps and empty metadata are not ownership proof; the
  ETag check cannot eliminate external-writer or lease-generation races.
  The changed automatic-recovery policy requires recorded SFI sign-off before
  merge, separately from user risk acceptance and any live-operation approval.

### Module manifest and release pipeline

- `LICENSE` at the repo root is referenced from the manifest's `LicenseUri`. The manifest fails its own self-check if the file isn't reachable.
- The ADO release pipeline stages, verifies, ESRP-signs and packages the module. GitHub Actions checksum-verifies and publishes that exact release asset without rebuilding or modifying it.

---

## 18. Testing

### Test framework

- Pester 5.5+.
- Before Windows Pester execution or concurrent shards start, open or create
  `HKCU\Software\Pester` with `RegistryKey.CreateSubKey` and dispose the handle.
  Preserve existing values and children; Pester creates and removes only its
  per-run subkeys. Never force-recreate the shared parent, suppress access
  failures or disable TestRegistry. Unix bootstrap remains unchanged.
- All tests use `Describe` / `Context` / `It` blocks; no Pester 4 syntax.
- Reserve `<name>` placeholders in test titles for actual `-TestCases`
  parameters; use another notation for illustrative paths.
- Avoid Pester automatic-variable names such as `$matches` and `$eventArgs` for
  local test data.
- Build runners fail on Pester setup/teardown block or test-container failures,
  even when every individual test reports a pass.
- Under strict mode, test property existence through
  `$object.PSObject.Properties[$name]`, and wrap possibly empty or single-item
  pipeline results in `@(...)` before using `.Count` or indexing.
- Windows build test entry points initialize Pester's shared
  `HKEY_CURRENT_USER\Software\Pester` parent key before invoking tests or
  launching shards. Standalone shard workers use the same initializer.
  Preserve an existing key; never force replacement or delete shared registry
  data. Retry only a creation `IOException` categorized as `ResourceExists`,
  rechecking the key before each attempt. The limit is three attempts with
  100 ms and 200 ms delays and visible retry diagnostics. Exhaustion rethrows
  the final error; probe failures, access denial and other errors fail
  immediately. Test assertions, test containers and entire test runs are never
  retried by this recovery.

### Layers

| Layer       | Folder                       | What runs                          | Network | Filesystem      |
| ----------- | ---------------------------- | ---------------------------------- | ------- | --------------- |
| Unit        | `tests/Pester/Unit/`         | Pure logic; mocks only             | No      | No              |
| Component   | `tests/Pester/Component/`    | Real FS under `TestDrive`; stub binaries via fixture scripts in `tests/fixtures/bin/` | No | Real            |
| Integration | `tests/Pester/Integration/`  | Packaged public-command acceptance against canonical and representative migration fixtures | Yes | Real |
| Qualification | `tests/Pester/Qualification/` | Minimal native compatibility and separately selected package/download/bootstrap proof | Yes | Real |

- Integration tests are tagged `-Tag Integration` and excluded from default local runs. Selected authoring pull-request and manual CI runs include them; main pushes do not.
- A stub-binary harness in `tests/fixtures/bin/` provides PowerShell scripts named `terraform.ps1`, `tflint.ps1`, etc. that emit pre-canned output. The resolver is hooked at test time to point at the stubs.

Terraform acceptance uses the built `out/Avm.Authoring` package and the public
`avm` dispatcher. Both canonical AzureRM and AzAPI fixtures must be correct
before execution: the first full `avm pre-commit` changes no authored bytes.
Snapshot that output, run the full public pre-commit a second time, and require
zero added, deleted or modified authored/managed source, docs, tests and tracked
lock/pin files. Then full `avm pr-check` must pass every expected step and leave
the same tree unchanged. Returned `Changed` arrays and Git's ignored-file status
are not substitutes for byte inventories.

One legacy user-flow fixture permits reviewed first-pass changes only, compared
with checked-in expected output independent of the transform executed by the
test. It covers utility upgrades, current telemetry, provider cleanup, modern
naming with compatible output references, owner headers, authored locations and telemetry opt-outs. The
second full public pre-commit must be byte-identical. Provider-mocked consumer
tests run without Azure authentication and with a loopback ModTM endpoint; the
temporary repository alone is committed before full pr-check. Keep tracked
Terraform locks in the before/after inventories. Only root Git metadata, new
Terraform working caches, and initially absent lock files created during
initialization in known configuration directories are transient. Do not ignore
all dotfiles, all ignored Git paths, or authored files under tool-like paths.

Missing policy-plan credentials block full local acceptance; do not skip a
required step, exclude a policy, or turn missing evidence into a pass. CI uses
the existing approved OIDC identity. Acceptance and qualification do not deploy
Azure resources. Qualification may run provider-mocked Terraform applies and
provider-free local plans, but never real-provider applies.

This mock boundary includes Terraform's built-in provider. Applying fixtures
that use `terraform_data` declare `terraform.io/builtin/terraform` explicitly,
provide `mock_provider "terraform" {}`, and include its binding in every
explicit run mapping that selects such a target. Provider-free setup targets
do not acquire unrelated bindings. An inspected literal plan in a preservation
regression may use unambiguous native built-in source proof for an authored mock without
adding a source declaration; that proof does not cover another run's explicit
or default apply command. Before a native test process starts,
inspect every selected local target's provider sources and test declarations.
Missing mocks, unproven sources, real test-provider configurations and partial,
unknown or cross-provider mappings fail closed. Root test files outside the
inspected suite and JSON tests are rejected. Public-command acceptance keeps
its real initialization and test execution, with the same guard at the test
subprocess boundary. Runtime credentials are cleared and runtime HTTP proxies
and ModTM endpoints are loopback-only; dependency inspection may still fetch
the pinned packages before runtime. Network isolation is not an exception to
the prohibition on real-provider applies.

Telemetry repeat-update qualification is bounded compositional proof, not an
unmodified end-to-end runtime test. Guard the generated `plantimestamp()`
expression and file hashes, obtain two distinct ordered timestamps from
provider-free native plans with a bounded harness-owned wait, and substitute
only that clock dependency in a temporary override. Preserve the stable-name
and changed-apply-ID assertions and require the native plan's exact `update`
action; reject creation, deletion, replacement and unexpected source changes.

Keep source/version matching, native response/argument contracts, provider
mapping decisions and safety predicates in unit tests. Real filesystem,
manifest, lock, cache, environment, rollback and subprocess-failure contracts
belong in component tests with stub processes. Do not move real native calls
into these tiers. Native HCL/token behavior, provider-schema selection,
downloaded inspection reuse and Terraform modern-naming output behavior require a
small native compatibility suite; mocks or duplicated formulas are not proof
of those semantics. Consolidate upstream permutations rather than rebuilding
whole transform fixtures for each decision. Install/download/attestation and
cold/offline package qualification run separately from module fixture jobs.

Repository-sync candidate validation uses the `static-unit-v1` acceptance
profile: all `pr-check` steps except `check policy` must pass, matching the
fork workflow's explicit Conftest exclusion. This profile runs non-authenticated
static analysis and unit tests only; Conftest, integration and E2E verification
are deferred to a separate full-module pre-release check, never reported as
passed. Normal standalone and module release validation defaults do not change.
Preparation, validation and publication run as ordered steps directly in the
`repository-management-sync.yml` matrix job, with one `avm` environment job per
repository and no nested reusable workflow. Keep workflow-wide and
repository-state concurrency, independent matrix failures, read-only contents permission and
step-scoped credentials. Validation failure blocks publication; plan-only runs
validate without publishing. Candidate and receipt artifacts remain diagnostic
outputs, not inter-job transfers. Keep the candidate identity configuration,
OIDC permission and existing `avm-validation` federation for future authenticated
checks, but the combined job does not use that environment's OIDC subject.
Restoring authenticated candidate checks requires a compatible isolation and
federation design first. Sharing the preparation environment and runner with
module-owned checks removes the former validation isolation boundary and
requires recorded SFI sign-off before merge. Terraform
unit tests run when discovered; an absent suite is a visible, non-blocking
`skipped` result, never a unit-test pass. Failures or execution errors in
existing suites block validation. Candidate-tree and publication safeguards
still apply when unit tests are absent. Validation receipts bind the acceptance
profile and actual static/unit statuses to the repository, base and tree;
publication rejects legacy or mismatched profiles and missing check evidence.
Unchanged or skipped candidates record checks as `not-run`, not passed.
Preparation produces a private archive and tree/path metadata, never a publication
patch. PR-check failure, invalid results or exceptions are logged immediately and
terminate validation before unit work. Every validation attempt first invalidates
its earlier receipt, including success for the same repository/base/tree.
Version 3 receipts also bind the prepared head, plan-only mode and authoring source
and version. Only receipt-verified publication reconstructs the immutable candidate
and generates its patch; missing/stale evidence blocks new and existing bot
pull requests before any push, creation, update or merge. Direct Terraform apply
without candidate staging is rejected. The shared publication core independently
requires matching validation evidence for module repositories. Non-module catalog
publication is unchanged; repository matrix failures remain independent.
Archive reconstruction must index the
committed bytes without Git content conversion, including historical CRLF
files. Restore normal attributes before checks and require the same exact
prepared tree; do not normalize the artifact or relax the tree comparison.
Both temporary checkouts must retain the original repository URL as their
Git origin so module classification does not depend on temporary directory
names or legacy telemetry prefixes. Setting that local identity must not
fetch from or write to the remote repository.

Manual plan-only repository-sync runs selecting workflow authoring source
must load the checked-out module during preparation bootstrap and optional
project synchronization, without first installing an unused Gallery release.
Only the combination of manual dispatch, plan-only mode and the source option
may select that checkout. Released-source, scheduled and apply runs retain
bounded Gallery installation retries. Missing or incompatible checkout
modules fail explicitly; they must not fall back to a release.

Build prerequisite installation uses the shared bounded retry policy. Exact-pinned
PowerShell Gallery prerequisites may additionally retry a caller-scoped HTTP 404
only when the rendered diagnostic contains the observed `Response status code does
not indicate success: 404 (Not Found)` or `HTTP 404` response text and an exact
`www.powershellgallery.com/api/v2/FindPackagesById` or `/api/v2/package/` request
endpoint. The same exact pin is reused on each attempt, and exhaustion rethrows
the original error. Generic 404 responses, authentication failures and
cancellation remain permanent or non-retryable under the shared classifier.

### Coverage

- 70% line coverage on `src/Avm.Authoring/` minimum, enforced via Pester `CodeCoverage`. CI build fails below the floor.
- Coverage is tracked per file; new files start with the floor and ratchet up as code matures.
- The coverage gate retains the unit inventory plus the filesystem suites
  relocated from it, so tier corrections do not remove production coverage.
  The complete component suite still runs independently on each OS; do not
  duplicate all component execution merely to move a test between tiers.

### Reusable Terraform module CI

The managed module caller invokes `terraform-module.yml` on pull-request
`opened`, `reopened`, and `synchronize` events, including draft and fork pull
requests. Neither the caller nor the automatic checks may add a label,
manual-approval, or changed-path prerequisite. GitHub's separate approval
policy for running workflows from external contributors still applies. The
managed caller remains an unconditional forwarder; fork handling and test-tier
decisions belong only in the reusable workflow.

Normal Terraform repository sync reconciles that repository-level policy to
`first_time_contributors` after verified Terraform configuration succeeds.
The GitHub Terraform provider does not expose this policy, so the existing
sync driver uses the dedicated GitHub REST endpoint through the shared CLI
helpers. Read and validate the current policy, write only when different,
and verify it again before reporting success. Plan-only runs report drift
without writing; `-WhatIf` makes no API calls. Failed reads, writes, and
readback stop the repository sync without a write retry or success fallback.
This does not change workflow token permissions, expose secrets to forks,
or bypass environment reviewers. Creation-mode bootstrap is unchanged;
the policy is reconciled when the repository enters normal sync.

One shared `unit-test` job runs independently on every invocation, with only
`contents: read`, no GitHub environment or subscription-selection dependency,
empty inherited secret/variable payloads, and OIDC disabled. Unit fixtures
and hooks must not require configured credentials. Fork `pr-check` uses the
same restrictions and excludes only `check policy` and its Conftest prerequisite.

Same-repository `pr-check` retains its full checks, subscription selection,
credentials and `pr-check` environment for Azure OIDC, but that environment
has no required reviewers. Preserve its Terraform resource address, environment
name and federated identity subject. Integration and e2e remain non-fork and
reviewer-gated, with their existing approval teams and bypass/self-review
settings. Integration keeps its `integration-test` environment unchanged.
E2e approval belongs to the non-matrix `discover-examples` job on `examples-test`,
which has no OIDC write permission. Every e2e matrix leg requires successful
subscription selection and protected discovery, plus a nonempty example list.
The legs use the distinct, approval-free `examples-test-execution` environment.
Preserve the template exclusion, subscription round-robin, required-feature
registration and cleanup. Discovery approval occurs before the example count is
known, so an empty matrix still needs that approval but executes no e2e legs.

Normal repository sync provisions the execution environment and its exact
repository/environment/reusable-workflow-bound federation on the existing test
identity. The execution environment name must not collide with any existing
environment, including case-insensitive names. Keep the existing environment
resource addresses, `examples-test` reviewers and legacy federation for older
workflow callers. Creation-mode bootstrap still omits test environments.
Reconcile the new environment and credential before relying on e2e execution;
missing federation must fail authentication, never fall back to another
environment or bypass discovery approval.

Removing the `pr-check` reviewer gate permits authenticated policy plans and
repository hooks on each same-repository PR push; the security stance's SFI
sign-off requirement applies before merge. Moving e2e approval from individual
execution jobs to their prerequisite and adding approval-free execution trust
also requires recorded SFI sign-off before merge.

### Scoped CI

Four independent workflows use GitHub's native `on.push.paths` and
`on.pull_request.paths` filters for pushes to `main` and pull requests targeting
`main`. Each also has `workflow_dispatch` to run its own suite without a file
change. There is no dispatcher, custom changed-file detection or cross-workflow
status aggregation.

| Workflow | File | Coverage |
| --- | --- | --- |
| `Authoring: CI` | `ci-authoring.yml` | Lint once on Ubuntu; authoring unit and component tests on Ubuntu, Windows and macOS; the Ubuntu unit leg enforces the 70% coverage floor. |
| `Authoring: Package qualification` | `ci-package-qualification.yml` | Cold/offline runtime dependencies, release downloads, checksums and ruleset attestation on all three operating systems when package/pin/bootstrap dependencies or packaged Bicep policy selectors change. |
| `Workflows: CI` | `ci-workflows.yml` | Workflow definitions, embedded installation behavior and CI contract tests on Ubuntu only. |
| `Repos: CI` | `repository-management-config-test.yml` | Repository-management unit/component tests, configuration checks and mocked Terraform validation on Ubuntu only. |

Authoring pull-request/manual runs retain both Terraform fixtures per OS and
one Bicep integration leg per OS. Main pushes skip both integration matrices.
Both Terraform legs run canonical public-command acceptance; the AzAPI leg
also runs the single legacy utility migration. Selection follows
`AVM_INTEGRATION_FIXTURE`; an unset selector runs the complete union. Discovery
tests require disjoint fixture selections and reject unassigned integration
files rather than silently treating non-Bicep filenames as Terraform tests.
Bicep-specific packaged metadata/compiler acceptance stays in the Bicep jobs.
A separate, credential-free native compatibility leg runs once per OS, not
once per Terraform fixture. Package qualification has its own path-filtered
workflow and reports. Native qualification remains required on authoring
pull-request/manual runs; it is not a nightly store for redundant matrices.
Existing integration environment approval and job-specific permissions remain
in place. Workflow and repository-management CI need no Azure credentials.

The static YAML filters include each area's source, tests, fixtures and
relevant workflow files. Authoring excludes repository-management and workflow
test directories, plus the dedicated repository component/fixture files.
Repository-management tests include the `BicepModuleIdentities`,
`BicepTestTenantSync`, `ModuleCatalog`, `Repository` and `TerraformCodeowners`
component filename families and the shared `TerraformInitUpgrade.Tests.ps1`
guard. Changes to shared build scripts, dependency installers, module bootstrap,
pinned dependencies or runtime helpers can trigger multiple workflows.
Keep these filters aligned when adding shared dependencies or test families.

The reusable `terraform-module.yml` is covered by Workflows and Repos CI, not
Authoring CI. Repository-only mocked Terraform validation lives in
`repository-management/repository-management.build.ps1`; the shared task graph
dot-sources its registration and preserves `./build.ps1 test-tenant-terraform`.
Keep repository-only task implementation changes outside `build/`. The
`build/**` filters remain intact for genuine shared-build changes.

Each workflow uploads and reports its own test artifacts. Unrelated
documentation-only changes intentionally skip the workflows; generated
`docs/reference/` changes still trigger authoring for drift validation.
Native path-filter limits and skip behavior apply. Do not require a
path-filtered workflow for every change; branch-protection configuration is
not modified by these workflows.

The build entry point's `-TestGroup Authoring` and
`-TestGroup RepositoryManagement` select test files only, not changed paths.
Serial, sharded and coverage runs use the same inventories. The default `All`
and full local `pre-commit` gate still run every unit/component group,
including workflow and repository-management tests.

---

## 19. Static analysis and pre-commit

- PSScriptAnalyzer settings live in `src/Avm.Authoring/Resources/PSScriptAnalyzerSettings.psd1`. A dedicated Ubuntu CI job runs lint once; informational findings, warnings, errors, and parse errors fail the gate.
- Keep `PSUseConsistentWhitespace` and `PSAlignAssignmentStatement` enabled with
  the repository's existing compatible settings.
- Pipeline-capable functions keep strict-mode initialization in `begin {}` to
  satisfy `PSUseProcessBlockForPipelineCommand`.
- Consumers wrap `Invoke-ScriptAnalyzer` results in `@(...)`; a no-finding
  result can otherwise be `$AutomationNull` on non-Windows hosts.
- The build invokes publicly discovered builtin rules serially through
  `IncludeRule`, retaining the original full inputs, settings, severities and
  custom-rule discovery arguments. A final custom-only partition excludes
  those builtins without enabling otherwise undiscovered custom rules.
  Parser `DiagnosticRecord` findings are identified by `ParseError` severity,
  not rule name, and retained once from the first full-input partition.
  All non-parser findings, including duplicates, remain intact.
- The build retry wrapper may retry only PSScriptAnalyzer's known transient
  `NullReferenceException` or a `CommandNotFoundException` whose `CommandName`
  is exactly `Get-Command`, including either failure inside an exception chain.
  Matching message text alone does not qualify a command-resolution failure.
  Both share the `AVM_LINT_MAX_ATTEMPTS` budget (eight total attempts by default)
  and the existing 500 ms incremental backoff. Each attempt covers the entire
  serial pass; failed attempts emit no partial findings. Exhaustion rethrows the original
  final error; unrelated exceptions fail immediately. The wrapper must never
  retry or hide analyzer findings.
- A `pre-commit` Pester suite runs:
  - Manifest layout (`Test-AvmModuleLayout`).
  - Encoding check (no BOM, LF line endings).
  - PSScriptAnalyzer with project settings.
  - Pester Unit layer.
  - Pester Component layer.
  - Generated cmdlet documentation drift validation.
- `build/avm.build.ps1` exposes this as `./build.ps1 pre-commit`; contributors run it before pushing.

---

## 20. Release and versioning

- Normal commands compare the running module against the latest PowerShell
  Gallery release and stop with upgrade guidance when outdated. `avm version`
  and `Get-AvmVersion` instead return the running version with an update warning.
  `avm upgrade` is the sole CLI self-update command and bypasses the guard so it
  can install the newer version.
  `-SkipModuleVersionCheck` is an explicit opt-out for automation and source
  checkouts. Composed commands forward it to module context resolution and
  nested steps; Gallery lookup failures warn and allow the command to continue.
- SemVer 2.0.0. Pre-release labels: `-preview.N`, `-rc.N`.
- One stable minor per quarter. Preview tags weekly off `main`.
- Breaking changes only at minor bumps **before** `1.0.0`, only at major bumps after.
- Release artefacts:
  - PSGallery via `Publish-PSResource` in `scripts/Publish-AvmAuthoring.ps1`. The workflow checks publisher code out from the default branch, so a release tag cannot influence code that receives the API key.
  - GitHub Release with the zipped module folder and a `SHA256SUMS` file.
- Bundled Bicep PSRule YAML lives under the visible
  `Resources/bicep/psrule/rules/` directory. The resolver passes this path
  explicitly; no `.ps-rule` directory convention is required. Keep all eight
  rule files and their bytes intact through the release-compatible archive
  route. Package acceptance compares the complete module file set, exact
  casing and bytes, and executes the extracted rules with PSRule. Local
  unsigned archive checks do not qualify production signatures or a release.
- Releases are split across ADO and GitHub. `.pipelines/release-avm-authoring.yml` in `github-private/azure/Azure-Verified-Modules` stages, ESRP-signs, verifies, packages and uploads the release assets, then promotes the prerelease. The GitHub Actions workflow runs on `release.released`, with a guarded `workflow_dispatch` fallback requiring the exact tag of an existing published full release. Both triggers use the same trusted default-branch code to download the signed zip and `SHA256SUMS`, validate checksum, layout, version and signature blocks, and publish the extracted module to PSGallery without rebuilding or modifying the release.
- The release pipeline is **idempotent / re-runnable**:
  - The GitHub PSGallery publish step passes `-SkipIfAlreadyPublished`, so re-running a tag whose version is already on the Gallery warns and exits 0 instead of failing.
  - ADO edits the existing prerelease and replaces its assets; it never creates the release or rewrites its human-authored notes.
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); release script verifies an entry exists for the new version before publishing.
- Manifest `Prerelease` field is set by the release script from the git tag; never edited by hand.

### Managed-files releases

`Azure/azure-verified-modules-managed-files` is versioned independently of the
module and released by hand through the GitHub UI. It has no release
automation, and adding some is out of scope.

- SemVer 2.0.0, tagged `vX.Y.Z`. The tag is the contract; nothing consumes
  branches except the `main` fallback for unpinned repos.
- **Patch or minor** for changes module repos can adopt on their own schedule.
  Repos warn until they upgrade, and the fleet sync rolls them forward
  opportunistically.
- **Major** to force adoption. Every pinned repo then errors on `avm pre-commit`
  until upgraded, `avm pr-check` fails, and the fleet sync upgrades regardless of
  open pull requests. Reserve it for changes that must land everywhere at once.

The fleet sync in `repository-management/` decides per repo whether to pass
`-Upgrade`. It upgrades when the delta is a major, and otherwise only when the
repo has no open pull request that a managed-file change could conflict with.
Draft pull requests, bot-authored pull requests, and pull requests untouched for
more than 14 days are ignored for that purpose. Lookup failures leave the repo on
its pin rather than guessing. A manual `workflow_dispatch` may set
`force_file_update` together with the existing repository selector to pass
`-Upgrade` for that subset regardless of release delta or open pull requests.
Scheduled and `repository_dispatch` runs cannot enable this override.

---

## 21. Telemetry

This section covers CLI telemetry, not generated module-deployment telemetry.
CLI settings must not affect a module's `enable_telemetry` input. A CLI
install ID must remain independent of module instance IDs, and the CLI must
not read or modify module telemetry state. Generating `main.telemetry.tf`
does not emit telemetry; the consumer's Terraform apply does.

- **Default**: off.
- **Opt-in**: `$env:AVM_TELEMETRY = 'on'` or `Set-AvmConfig -Telemetry On`.
- **Payload**: verb name, exit code, duration in ms, OS, architecture, CLI version, anonymised install ID (UUID v4 generated once and stored in `<Config>/install-id`).
- **Never sent**: repo paths, module names, env vars, error messages, user identity, file contents, hostnames.
- **Endpoint and storage**: not implemented. Any implementation must update this
  specification and preserve the privacy contract before code is merged.

---

## 22. Documentation

- Comment-based help on every public function is the source of truth for command-level docs. A docs job generates `docs/reference/<cmdlet>.md` from it.
- This repo treats generated public-cmdlet reference pages as part of the checked-in contract. Every public help, parameter, or exported-function change requires `./build.ps1 docs` followed by a commit of the updated Markdown files.
- `./build.ps1 docs-check` compares the generated content without writing. It is part of `pre-commit`, `ci`, `ci-tests`, `ci-unit`, and `ci-coverage`, so stale generated Markdown fails local and pull-request validation.
- The generated docs are for both human readers and agent consumers. Each page should document the cmdlet purpose, behaviour, and each parameter's role in plain language. Doc generation must preserve the public help semantics; do not hand-edit generated output to hide drift.
- `docs/` in this repo holds:
  - `quality-spec.md` — this file and the only normative engineering document.
  - `reference/` — generated per-cmdlet reference.
- The repo `README.md` points users at the generated reference and contributors at this spec.
- `MAINTAINERS.md` lists AVM core team contacts and review owners.

---

## 23. Architecture decisions

1. **Credential storage.** Do not add repository-owned plaintext credential
   storage. When durable credentials become necessary, use an established
   cross-platform secret-management abstraction and threat-model it first.
2. **Console encoding on Windows.** Configure UTF-8 at module import unless
   `AVM_NO_CONSOLE_CONFIG=1` is set.
3. **Cancellation semantics.** Forward cancellation to child processes using
   the platform-specific shared process helper; do not add command-local
   cancellation implementations.
4. **Tool resolution.** Prefer the managed cache for determinism. PATH fallback
   is explicit and accepts only a binary that reports the selected version.
5. **Native packaging.** Do not add a .NET front end or `dotnet tool` package
   without a demonstrated user requirement that PowerShell cannot meet cleanly.
6. **Windows path length.** Keep generated paths short enough that the module
   does not require changing an operating-system long-path setting.

---

## 24. Glossary

- **AVM** — Azure Verified Modules.
- **Lock manifest** — `src/Avm.Authoring/Resources/avm.pins.jsonc`. Pins every managed tool's version and SHA256.
- **Managed tool** — any binary the CLI installs and resolves itself (Terraform, TFLint, `avmfix`, …).
- **Managed-file pin** — `<repo>/.avm/managed-files-version.json`. Records the managed-files release a repo is synced against, per §8.
- **Module context** — the `pscustomobject` returned by `Get-AvmModuleContext` describing a Bicep or Terraform module's root, ecosystem, scope, and owner.
- **Public verb** — a verb exposed to end users through the `avm` dispatcher
  and an approved-verb cmdlet documented in `docs/reference/`.
- **Tier 1 / Tier 2** — OS support tiers defined in §2.
- **Repo-local state** — anything written under `<repo>/.avm/` per §8.
- **User state** — anything written under the per-user folders per §7.

---

## 25. References

- [XDG Base Directory Spec](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
- [Apple File System Programming Guide — Standard Directories](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
- [Windows Known Folders](https://learn.microsoft.com/windows/win32/shell/knownfolderid)
- [PowerShell Approved Verbs](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)
- [PSScriptAnalyzer rules](https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/readme)
- [Pester 5 docs](https://pester.dev/)
- [SemVer 2.0.0](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- [NO_COLOR](https://no-color.org)
- [Microsoft.PowerShell.PSResourceGet — Publish-PSResource](https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/publish-psresource)
