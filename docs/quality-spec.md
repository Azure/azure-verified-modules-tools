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

Every public verb produces **byte-identical exit codes**, **structurally identical JSON output** (under `--json`), and **semantically identical filesystem effects** across every Tier 1 platform listed above. CI proves this by running the full Pester matrix on Windows `x64`, Linux `x64`, Linux `arm64`, and macOS `arm64`. A test failure on any one of those four is a release blocker.

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
      ci.yml
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
before confirmation and registers the features once per selected subscription
after the identity check and before validation; a registration failure fails
the case without deploying.

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
receive the parent's opt-out, and supported example calls expose and forward
missing inputs. Only newly generated example `location` inputs default to
`"eastus"`, so runnable examples remain usable by noninteractive plans.
Authored example declarations, defaults, required inputs, and per-item regions
are preserved; reusable module inputs still receive no default. Override the
example value when another region or cloud is required.
Variable blocks are sorted after missing location inputs are
created, so the first transform already satisfies drift checks.

Instrumented roots and children run the `root,module,common` profiles; other
module scopes run `module,common`. Profiles execute sequentially so module
provider rules see the generated telemetry. A second `module-call,common`
pass visits local modules from deepest to root after their inputs exist.
Examples run `example,provider-cleanup,common`; standalone test modules run
`provider-cleanup` followed by any consumer `test` profile. MaPoTF subprocesses
clear `TF_PLUGIN_CACHE_DIR` and use target-local providers, so independent
targets can run in parallel without racing Terraform's shared provider cache.

`main.telemetry.tf` reads `telemetryIdPrefix` from the module's own
`metadata.json` at apply time. When telemetry is enabled, it creates an
empty `Microsoft.Resources/deployments@2025-04-01` deployment at the active
subscription scope. Its reporting payload is solely the deployment name:
`<telemetryIdPrefix>.<version>.<source>.<instance>`. The full version comes
from the matching `path.module` entry in Terraform's modules manifest, with
periods changed to hyphens; an unavailable version is `0-0-0`. The one-letter
source token is `t` (Terraform Registry), `o` (OpenTofu Registry), `g` (Git),
or `x` (other); the raw source path is never reported. The stable instance
suffix is four hex characters derived from `terraform_data.telemetry`'s ID.
The module catalog maps the metadata prefix to its canonical type. A
precondition rejects a version with unsupported name characters or a
combined name longer than 64 characters; neither is silently truncated.

The empty template contains the Bicep-style information output and a
non-reporting `apply_id` output set to `plantimestamp()`. This changes the
resource body once per normal plan, forcing an in-place deployment PUT even
on an otherwise no-op apply while leaving the name stable. Refresh-only
plans do not write telemetry. No reporting tags or tier are sent.
The deployment identity needs `Microsoft.Resources/deployments/read`,
`Microsoft.Resources/deployments/write`, and
`Microsoft.Resources/deployments/delete` at the subscription scope; see
<https://aka.ms/avm/telemetry>.

The generated AzAPI resource sets `response_export_values = []`. Only this
tagless telemetry deployment receives a scoped inline TFLint exemption
from the generic AzAPI tagging rule; that rule remains enabled for every
other AzAPI resource. The transform engine adds the directive after MaPoTF
writes the resource because `asraw` blocks do not retain comments.
The lint warning audit skips only that exact directive
above a tagless generated telemetry deployment; other inline ignores still
warn. The packaged root TFLint profile disables the retired
`modtm` provider requirement, as the module and example profiles already do.

The packaged AVM TFLint ruleset is pinned to attested release v1.2.0.
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
not delete their remote objects. Terraform must still install their former
providers once when an existing state references them; after the state
forgets those addresses, new installations do not require `modtm`. The
random provider requirement is removed only if no other random resources
or data sources remain in the module. The transform also removes obsolete
`modtm` provider declarations in examples and standalone test modules when
they have no remaining `modtm` resources or data sources, empty `modtm` test
mocks, and standard references to the old telemetry resource. Direct unit
tests receive a missing AzAPI mock when retiring their empty modtm mock;
empty AzAPI mocks receive a valid synthetic subscription resource ID for
`azapi_client_config`. Authored non-empty AzAPI mocks are preserved.
Their client-config defaults must provide a full `/subscriptions/<guid>`
resource ID, not a bare GUID. Published dependencies and legacy telemetry
in scopes without a telemetry prefix are not migrated by the root profile.
MaPoTF 0.3.0 inspects each direct `tests/unit/*.tftest.hcl` file before source
transformation. Root runs and explicitly selected, known local module
targets, including discovered standalone test setup and wrapper modules,
are supported; remote or unknown targets fail without fetching them.
Only root and child modules establish test-file ownership; standalone
test targets do not change which files are direct unit tests.
After source transformation, only a target that gained a previously absent,
required `location` input receives a per-run `location = "eastus"` in its
provider-mocked tests. Existing global and per-run values, including nulls
and expressions, remain authored. This test-only value is not a production
default and never replaces per-hub regions or repairs unrelated pre-existing
missing inputs. Assertions, targets and telemetry opt-outs are preserved.
Real-provider declarations, aliased mocks and provider mappings still require
review rather than being silently changed; an AzureRM mock alone cannot cover
new AzAPI telemetry. Integration tests do not receive new mocks or locations.
Non-empty modtm test mocks and remaining
author-owned `modtm` resources or data sources fail with
actionable diagnostics instead of being silently rewritten. When random was
used only by retired telemetry, standard empty `mock_provider "random"`
blocks in direct unit tests are removed if the owner, selected local test
targets, their known local children, and test setup no longer need that
provider. Non-empty mocks or remaining random
references fail for manual review; mocks for other random use are preserved.
JSON configurations and module dependencies that cannot be checked locally
also retain their random mocks rather than assuming the provider is unused.

`avm pre-commit` and `avm pr-check` resolve their required tools before the
first step, which validates metadata for the selected root and its module
children. Missing or invalid metadata fails and stops either chain before
other steps, without changing module files or reading indexes. `avm pr-check`
also requires a clean worktree before tool resolution. `-Verbose` logs the
discovered module count, each validated metadata path, and any issues.
`avm pr-check -ExcludeSteps` accepts an array of any of its nine step names:
`metadata`, `sync`, `format`, `transform`, `lint`, `check policy`,
`check convention`, `validate`, and `docs`. Names are case-insensitive and
validated before execution; an empty array keeps the default chain. Explicit
exclusions bypass only those steps, including the metadata stop and required
Bicep result checks for an excluded step. Each is reported as `skipped` with an
exclusion reason. Non-excluded checks retain their ordering and failure rules;
version and clean-worktree guards remain mandatory. An entirely excluded chain
reports overall `skipped`, not `pass`.
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
Terraform repository discovery reads validated root metadata from each
repository's default branch. Missing files warn during rollout and suppress
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
packaged `avm-readme-v1.scriban` is used by default through the compiler's
`--template-file` option, without creating caller config or template files.
An explicit `documentation.template.file` in the nearest `bicepconfig.json`
must reference a relative canonical copy; a different template or hash fails
before writing. Generated content comes from the
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
round-robin case assignment, rather than the registry's `Get-Random`
permutation. Explicit subscription selection takes precedence over ambient
CI pools. Resource placement uses the owning module's canonical resource
type when available; pattern/helper or absent metadata uses the generic
allowed-region list. Explicit parameter, token and resource-location pins
must agree. Only wholly regional validation failures can relocate an
unpinned, non-global, non-resource-group case. Metadata location and
`baseTime` stay fixed. Record every attempt before submission, verify the
native response's exact deployment ID, and retry only confirmed failure or
exact preflight rejection. A submission timeout watches the same deployment
for up to an hour (stopping after three consecutive read timeouts); a
recovered `Failed` state counts as confirmed. Unknown or cancelled outcomes
never resubmit. A confirmed deployment failure whose operation errors are all regional
may also relocate an eligible case: strict cleanup must first confirm every
deployment is terminal and fully discovered, remove its resources (no retained
or soft-deleted names) and delete its deployment records. Otherwise relocation
stops and ordinary cleanup runs. Rejected regions and attempt numbers carry
forward, so relocation never exceeds the validation or deployment budgets.

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
`-KeepResources` runs assertions but skips both the post hook and cleanup.

The private version-1 JSON state allows only target identifiers, status,
verified group ownership tags and the small amount of resource metadata
needed after deletion, plus the case path, source fingerprint and
completion-started marker. It never stores credentials, parameter values,
deployment outputs or raw Azure responses. Create a unique local temporary
file by default; an explicit path resolves against the caller's PowerShell
location. Never overwrite an existing file during creation. Updates use a
flushed, exclusive sibling temporary file followed by an atomic replacement,
and retain the last valid state if serialization fails. State survives
temporary-template and parameter-file cleanup.

Capture post-removal metadata before deleting resources or their parents.
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
- Both composite commands resolve and import-check all applicable prerequisites
  before metadata/step 1, after the module-upgrade and context/clean-tree guards.
  `pr-check -ExcludeSteps` removes prerequisites used only by excluded steps,
  retaining those shared with any remaining step. Default prerequisite sets and
  resolution order are unchanged.
  Standalone metadata, Bicep Pester, YAML and PSRule entrypoints share the same
  mechanism. Build prerequisites supply that same Pester pin, and all test
  runners, including isolated shards, import it through the shared resolver.
  Reject a different already-loaded module version with fresh-session guidance
  before composite step 1.

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

- Every `uses:` reference in `.github/workflows/*.yml` is pinned to a 40-character commit SHA, with the human-readable version as a trailing `# vX.Y.Z` comment. Floating tag references (`@v5`, `@main`, branch refs) are rejected at PR review. Rationale: a single tag-repoint on a compromised maintainer account would deliver attacker-controlled code into every CI run on the next push, and that code runs with `GITHUB_TOKEN`, `secrets.*`, OIDC mint rights, and full write access to the working tree. SHA pinning closes that vector at the cost of needing a maintenance loop for security fixes; that loop is Dependabot.
- `.github/dependabot.yml` enables the `github-actions` ecosystem on a weekly cadence, batches minor/patch bumps to reduce noise, and keeps major bumps as individual PRs so they get individual review.
- Every workflow declares an explicit top-level `permissions:` block. Default is `permissions: contents: read`. Write scopes (`contents: write`, `packages: write`, `id-token: write`, etc.) are added job-by-job with an inline comment justifying why.
- `actions/checkout` is always called with `persist-credentials: false` outside the release pipeline so the cloned repo's `.git/config` doesn't carry a token usable by any subsequent step or any subprocess that reads from the working tree.

### Tool binary supply chain

- Default binary and PowerShell package downloads are SHA256-verified against `Resources/avm.pins.jsonc` (section 10). A mismatch throws `AvmToolException` with both hashes. Only the explicit repository version-override exception may bypass the pinned hash for named tools, using a separate unverified cache and visible warning.
- `scripts/Update-AvmPins.ps1` is the only sanctioned path to rotate a hash; the PR that lands the rotation must record what was updated and which upstream release notes were reviewed.
- The repo bundles no precompiled binaries. Everything is fetched at first use and cached under the user's standard cache root (section 7).

### Module manifest and release pipeline

- `LICENSE` at the repo root is referenced from the manifest's `LicenseUri`. The manifest fails its own self-check if the file isn't reachable.
- The ADO release pipeline stages, verifies, ESRP-signs and packages the module. GitHub Actions checksum-verifies and publishes that exact release asset without rebuilding or modifying it.

---

## 18. Testing

### Test framework

- Pester 5.5+.
- All tests use `Describe` / `Context` / `It` blocks; no Pester 4 syntax.
- Reserve `<name>` placeholders in test titles for actual `-TestCases`
  parameters; use another notation for illustrative paths.
- Avoid Pester automatic-variable names such as `$matches` and `$eventArgs` for
  local test data.
- Under strict mode, test property existence through
  `$object.PSObject.Properties[$name]`, and wrap possibly empty or single-item
  pipeline results in `@(...)` before using `.Count` or indexing.

### Layers

| Layer       | Folder                       | What runs                          | Network | Filesystem      |
| ----------- | ---------------------------- | ---------------------------------- | ------- | --------------- |
| Unit        | `tests/Pester/Unit/`         | Pure logic; mocks only             | No      | No              |
| Component   | `tests/Pester/Component/`    | Real FS under `TestDrive`; stub binaries via fixture scripts in `tests/fixtures/bin/` | No | Real            |
| Integration | `tests/Pester/Integration/`  | Pulls and runs the real managed tools from the resolver against the on-disk fixtures | Yes | Real |

- Integration tests are tagged `-Tag Integration` and excluded from default runs. CI runs them on pull requests via the `integration` job in the `ci` workflow.
- A stub-binary harness in `tests/fixtures/bin/` provides PowerShell scripts named `terraform.ps1`, `tflint.ps1`, etc. that emit pre-canned output. The resolver is hooked at test time to point at the stubs.

Repository-sync candidate validation requires static checks to pass. Terraform
unit tests run when discovered; an absent suite is a visible, non-blocking
`skipped` result, never a unit-test pass. Failures or execution errors in
existing suites block validation. Candidate-tree and publication safeguards
still apply when unit tests are absent. Archive reconstruction must index the
committed bytes without Git content conversion, including historical CRLF
files. Restore normal attributes before checks and require the same exact
prepared tree; do not normalize the artifact or relax the tree comparison.

### Coverage

- 70% line coverage on `src/Avm.Authoring/` minimum, enforced via Pester `CodeCoverage`. CI build fails below the floor.
- Coverage is tracked per file; new files start with the floor and ratchet up as code matures.

### CI matrix

Every PR runs Unit + Component on:

- `windows-2025` (`x64`)
- `ubuntu-24.04` (`x64`)
- `ubuntu-24.04-arm` (`arm64`)
- `macos-15` (`arm64`)

Integration runs on every pull request via the `integration` job in the `ci` workflow on each of the above.

---

## 19. Static analysis and pre-commit

- PSScriptAnalyzer settings live in `src/Avm.Authoring/Resources/PSScriptAnalyzerSettings.psd1`. A dedicated Ubuntu CI job runs lint once; informational findings, warnings, errors, and parse errors fail the gate.
- Keep `PSUseConsistentWhitespace` and `PSAlignAssignmentStatement` enabled with
  the repository's existing compatible settings.
- Pipeline-capable functions keep strict-mode initialization in `begin {}` to
  satisfy `PSUseProcessBlockForPipelineCommand`.
- Consumers wrap `Invoke-ScriptAnalyzer` results in `@(...)`; a no-finding
  result can otherwise be `$AutomationNull` on non-Windows hosts.
- The build retry wrapper may retry only PSScriptAnalyzer's known transient
  `NullReferenceException`. It must never retry or hide analyzer findings.
- A `pre-commit` Pester suite runs:
  - Manifest layout (`Test-AvmModuleLayout`).
  - Encoding check (no BOM, LF line endings).
  - PSScriptAnalyzer with project settings.
  - Pester Unit layer.
  - Generated cmdlet documentation drift validation.
- `build/avm.build.ps1` exposes this as `./build.ps1 pre-commit`; contributors run it before pushing.

---

## 20. Release and versioning

- Normal commands compare the running module against the latest PowerShell
  Gallery release and stop with upgrade guidance when outdated. `avm version`
  and `Get-AvmVersion` instead return the running version with an update warning.
  `avm upgrade` bypasses the guard so it can install the newer version;
  `avm update` remains a backwards-compatible alias.
  `-SkipModuleVersionCheck` is an explicit opt-out for automation and source
  checkouts. Composed commands forward it to module context resolution and
  nested steps; Gallery lookup failures warn and allow the command to continue.
- SemVer 2.0.0. Pre-release labels: `-preview.N`, `-rc.N`.
- One stable minor per quarter. Preview tags weekly off `main`.
- Breaking changes only at minor bumps **before** `1.0.0`, only at major bumps after.
- Release artefacts:
  - PSGallery via `Publish-PSResource` in `scripts/Publish-AvmAuthoring.ps1`. The workflow checks publisher code out from the default branch, so a release tag cannot influence code that receives the API key.
  - GitHub Release with the zipped module folder and a `SHA256SUMS` file.
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
- `./build.ps1 docs-check` compares the generated content without writing. It is part of `pre-commit`, `ci`, and `ci-tests`, so stale generated Markdown fails local and pull-request validation.
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
