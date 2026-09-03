# AVM CLI Implementation Spec

Engineering rules for building the `Avm.Authoring` PowerShell module (working CLI name `avm`).

This document is the companion to [avm-consolidation-plan.md](avm-consolidation-plan.md). The plan answers **what** we are building and **why**, in phases. This spec answers **how** we build it — file layout, naming, OS portability, error handling, testing, release — at a level a contributor can pick up once and then write spec-compliant code without further coaching.

When this spec and the plan disagree, this spec wins for implementation details and the plan wins for scope and sequencing.

---

## Security stance

Security is the **top non-functional priority** for this module, in line with the Microsoft Secure Future Initiative (SFI). Every other rule in this spec is subordinate to it; when a spec rule and a security control disagree, the security control wins, and any change that loosens a security control requires an SFI sign-off recorded in the PR.

The stance has three pillars:

- **Secure by design.** Every new public verb, network call, subprocess invocation, file write, and credential touch is threat-modelled at PR time (what data is handled, which identities are touched, which dependencies are added, what the blast radius is on compromise). New code that fails the threat-model pass is rejected — patches do not happen post-merge.
- **Secure by default.** Defaults never compromise the user. TLS 1.2 minimum (section 16). `GITHUB_TOKEN: contents: read` unless a write scope is justified job-by-job (section 17). No `-SkipCertificateCheck` (section 16). No plain-text secrets in parameter form (section 17). No `Invoke-Expression`, no `cmd /c`, no `bash -c` on user input (section 9). No PATH-resolved tool execution unless the caller explicitly opts in with `-AllowPathFallback` (section 10).
- **Secure operations.** Every external dependency is pinned and integrity-verified. Workflow actions are pinned to commit SHA (section 17). Tool binaries are pinned by SHA256 in `Resources/avm.pins.jsonc` and verified on every download (section 10). PowerShell module dependencies are floor-pinned in the workflow with the release pipeline as the upgrade gate (section 20). Dependabot keeps the action SHAs fresh; the lock-refresh script keeps the tool SHAs fresh — both rotations are PR-reviewed.

A successful supply-chain attack against any of these dependencies must, by construction, require either a SHA collision (impractical) or a deliberate maintainer-side PR that re-publishes a known-good SHA — never a silent tag-repoint or a transparent version drift.

---

## 1. Scope and audience

- **Audience**: contributors to this repository (`Azure/azure-verified-modules-tools`).
- **In scope**: code conventions, OS portability, public API shape, manifest rules, tool-cache layout, testing, release, security.
- **Out of scope**: anything in the consolidation plan's Phase 4 onwards specifics (porting `mapotf`/`grept` rules, governance script consolidation) — those phases will get their own per-phase design notes.
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
| `az`       | Optional — required only for `avm test integration` and `avm test e2e` | 2.60+ |
| .NET SDK   | Optional — required only if Phase 3 Hybrid mode is enabled locally | 9.0+ |

Everything else (Terraform, TFLint, `terraform-docs`, Conftest, `avmfix`, `mapotf`, `grept`, Bicep) is installed and managed by the CLI per §10.

---

## 3. Cross-OS guarantees

Every public verb produces **byte-identical exit codes**, **structurally identical JSON output** (under `--json`), and **semantically identical filesystem effects** across every Tier 1 platform listed above. CI proves this from Phase 0 onwards by running the full Pester matrix on Windows `x64`, Linux `x64`, Linux `arm64`, and macOS `arm64`. A test failure on any one of those four is a release blocker.

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
    avm-consolidation-plan.md
    avm-implementation-spec.md    # this file
    quality-standards.md          # cross-cutting standards + traps
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

> See also: [`quality-standards.md`](quality-standards.md) for the consolidated cross-cutting standards (encoding, cross-OS rules, subprocess invocation, PSScriptAnalyzer + Pester traps).

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
    managed-files.json           # per-repo managed-files sync-source override
    managed-files-version.json   # managed-files release pin (CLI-managed)
    context.psd1                 # per-repo context override
    .disable                     # zero-byte sentinel — CLI refuses to run if present
```

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

Extends §6 of the consolidation plan with concrete OS-aware paths and file conventions.

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
}
```

- All URLs are `https://`. A non-`https://` URL fails the schema check.
- The `{os}` placeholder resolves to `windows`, `linux`, or `darwin`. The `{arch}` placeholder resolves to `amd64` or `arm64`.
- The `entrypoint` value is always lowercase. On Windows the resolver appends `.exe` only when computing the final path.

### Cache layout

```text
<Data>/tools/<tool>/<version>/
    <entrypoint>[.exe]      # the binary
    .verified                # zero-byte marker — present iff SHA matched and unpack succeeded
    .meta.json               # { url, sha256, installedAt, source, archive }
```

- Atomic install: extract to `<Data>/tools/<tool>/.staging/<short-uuid>/`, verify SHA, then `Move-Item` (rename) to `<Data>/tools/<tool>/<version>/`. On rename failure (someone else got there first), discard the staging dir and use whoever won the race.
- Cross-process lock: file lock on `<Data>/tools/<tool>/.lock` while installing; lock held via `[System.IO.File]::Open(..., FileMode.OpenOrCreate, FileAccess.Write, FileShare.None)`.
- The `.verified` marker is the only thing the resolver looks at to decide a cached install is good. Missing marker = re-install.
- `avm tool install --force` deletes `<Data>/tools/<tool>/<version>/` and re-installs.

### Lookup order on every invocation

1. **Cache** — `<Data>/tools/<tool>/<version>/<entrypoint>[.exe]` exists and `.verified` marker present → use it.
2. **PATH (opt-in)** — only when the caller passes `-AllowPathFallback` (the engines' opt-in switch; off by default). `Get-Command <entrypoint>` → if found and it reports the locked version, use it. If found but the version is wrong, warn once and fall through to install. The gauntlet verbs do **not** enable this by default, so PATH is normally ignored in favour of the pinned managed tool.
3. **Auto-install (default)** — a cache miss transparently installs the locked version from the lock file, into the cache, verifying its SHA-256 (same atomic, locked, `.verified`-marked path as `avm tool install`). A concise progress message is emitted the first time so a first run is not a mysterious pause. This is on by default both locally and in CI — the consumer never needs to run a separate install step. Set `AVM_NO_AUTO_INSTALL=1` (or pass `-NoAutoInstall`) to disable it for locked-down / air-gapped environments; a cache miss then fails fast with an actionable `avm tool install <tool>` message instead of downloading. `AVM_OFFLINE=1` and `AVM_MIRROR` still apply to the download (see below).

`avm tool list` mirrors this exact order: it reports `installed` for a cache hit, `not-installed` when a cache miss would auto-install, `auto-install-disabled` when a cache miss would hard-fail under `AVM_NO_AUTO_INSTALL`, and `installed-on-path` / `outdated-on-path` only when invoked with `-AllowPathFallback`. It never claims a tool is usable via PATH that the engines would actually ignore.

### Offline mode

- `AVM_OFFLINE=1` → resolver refuses any HTTP traffic. Cache hit succeeds; cache miss fails fast with a clear message naming the missing tool.
- `AVM_MIRROR=https://internal.example.com/avm-mirror` → every `urlTemplate` is rewritten before download. The mirror's scheme, authority, and path prefix are preserved; the source URL's path-and-query is appended verbatim. With the example above, `https://releases.hashicorp.com/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip` is fetched from `https://internal.example.com/avm-mirror/terraform/1.9.5/terraform_1.9.5_linux_amd64.zip`. The mirror itself MUST be `https://`; an `http://` mirror is refused with `AvmConfigurationException` so a misconfigured proxy cannot silently downgrade TLS. `file://` source URLs (test fixtures) are never rewritten.

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

> See also: [`quality-standards.md`](quality-standards.md) § 10 for the lessons-learned view of typed exceptions, the `AvmConfigurationException → skipped` convention, and stable error codes.

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
  - Retries on 5xx and connection errors with exponential backoff (3 attempts, 1 s / 4 s / 16 s).
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

- Every binary downloaded by `Resolve-AvmTool` is SHA256-verified against `Resources/avm.pins.jsonc` (section 10). A mismatch throws `AvmToolException` with both the expected and the actual hash. The lock file is the only sanctioned source of truth.
- `scripts/Update-AvmPins.ps1` is the only sanctioned path to rotate a hash; the PR that lands the rotation must record what was updated and which upstream release notes were reviewed.
- The repo bundles no precompiled binaries. Everything is fetched at first use and cached under the user's standard cache root (section 7).

### Module manifest and release pipeline

- `LICENSE` at the repo root is referenced from the manifest's `LicenseUri`. The manifest fails its own self-check if the file isn't reachable.
- The ADO release pipeline stages, verifies, ESRP-signs and packages the module. GitHub Actions checksum-verifies and publishes that exact release asset without rebuilding or modifying it.

---

## 18. Testing

> See also: [`quality-standards.md`](quality-standards.md) § 6 for Pester 5 traps (`<word>` placeholder collision, auto-var collisions, strict-mode 3.0 property access) and § 8 for the test-layering contract.

### Test framework

- Pester 5.5+.
- All tests use `Describe` / `Context` / `It` blocks; no Pester 4 syntax.

### Layers

| Layer       | Folder                       | What runs                          | Network | Filesystem      |
| ----------- | ---------------------------- | ---------------------------------- | ------- | --------------- |
| Unit        | `tests/Pester/Unit/`         | Pure logic; mocks only             | No      | No              |
| Component   | `tests/Pester/Component/`    | Real FS under `TestDrive`; stub binaries via fixture scripts in `tests/fixtures/bin/` | No | Real            |
| Integration | `tests/Pester/Integration/`  | Pulls and runs the real managed tools from the resolver against the on-disk fixtures | Yes | Real |

- Integration tests are tagged `-Tag Integration` and excluded from default runs. CI runs them on pull requests via the `integration` job in the `ci` workflow.
- A stub-binary harness in `tests/fixtures/bin/` provides PowerShell scripts named `terraform.ps1`, `tflint.ps1`, etc. that emit pre-canned output. The resolver is hooked at test time to point at the stubs.

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

> See also: [`quality-standards.md`](quality-standards.md) § 5 for the `AvmAvoidStringThrow` custom rule, the transient `NullReferenceException` mitigation and retry wrapper, the cross-platform `@(...)` consumer wrap, and the known PSSA rule conflicts.

- PSScriptAnalyzer settings in `src/Avm.Authoring/Resources/PSScriptAnalyzerSettings.psd1`. CI runs `Invoke-ScriptAnalyzer -Path src/ -Settings <path>` and treats `Warning` and above as fixable, `Error` as blocking.
- A `pre-commit` Pester suite runs:
  - Manifest layout (`Test-AvmModuleLayout`).
  - Encoding check (no BOM, LF line endings).
  - PSScriptAnalyzer with project settings.
  - Pester Unit layer.
- `build/avm.build.ps1` exposes this as `./build.ps1 pre-commit`; contributors run it before pushing.
- Terraform `avm pr-check` policy analysis is credential-free. For each active
  example, the engine stages any missing provider declarations, generates a
  temporary `terraform test` file with native `mock_provider` blocks, and passes
  the emitted `test_plan` JSON to APRL and AVMSEC through Conftest. Real Azure
  authentication is reserved for the integration and end-to-end module tiers,
  enabling a separately released workflow-template update to run the static PR
  check on fork pull requests.

---

## 20. Release and versioning

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

## 21. Telemetry (deferred to Phase 3)

- **Default**: off.
- **Opt-in**: `$env:AVM_TELEMETRY = 'on'` or `Set-AvmConfig -Telemetry On`.
- **Payload**: verb name, exit code, duration in ms, OS, architecture, CLI version, anonymised install ID (UUID v4 generated once and stored in `<Config>/install-id`).
- **Never sent**: repo paths, module names, env vars, error messages, user identity, file contents, hostnames.
- **Endpoint and storage**: TBD in the Phase 3 design note; this spec just locks the privacy contract.

---

## 22. Documentation

- Comment-based help on every public function is the source of truth for command-level docs. A docs job generates `docs/reference/<cmdlet>.md` from it.
- `docs/` in this repo holds:
  - `avm-consolidation-plan.md` — the phased plan.
  - `avm-implementation-spec.md` — this file.
  - `quality-standards.md` — cross-cutting standards and traps.
  - `reference/` — generated per-cmdlet reference (Phase 1 onwards).
  - `user-guide.md` — getting started for module authors (Phase 1 onwards).
- The repo `README.md` points new contributors at this spec and the plan.
- `MAINTAINERS.md` lists AVM core team contacts and review owners.

---

## 23. Open implementation questions

1. **Credential storage.** Use `Microsoft.PowerShell.SecretManagement` (well-supported, cross-platform via SecretStore vault) or a simple file-based store under `<Config>/secrets/` with OS-keychain integration later? Lean: SecretManagement when we first need it (probably Phase 3).
2. **Console encoding on Windows.** Should the module set `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` at import time on Windows so child processes inherit it? Cleaner output but mutates process state. Lean: yes, behind a `-NoConsoleConfig` opt-out. Decide in Phase 0.
3. **Cancellation semantics on Windows.** Windows has no `SIGINT`; we use `GenerateConsoleCtrlEvent` with `CTRL_BREAK_EVENT`. Behaviour with detached child processes (no shared console) needs a Phase 0 spike.
4. **Tool resolver and external version managers.** Honour `mise` / `asdf` / `tenv`'s shims when found on PATH and skip our own install for those tools, or always prefer our cache for determinism? Lean: prefer our cache, but accept the shim's version if it matches the lock exactly.
5. **`dotnet tool` packaging.** Adopt as a Phase 0 distribution channel for future-proofing, or wait for Phase 3 Hybrid mode? Lean: wait — packaging effort isn't justified until Hybrid is real.
6. **Long-path support on Windows.** Force-enable via manifest application manifest, or document `New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1` as a prerequisite? Lean: keep paths short enough (§6) that the question doesn't matter.

---

## 24. Glossary

- **AVM** — Azure Verified Modules.
- **Lock manifest** — `src/Avm.Authoring/Resources/avm.pins.jsonc`. Pins every managed tool's version and SHA256.
- **Managed tool** — any binary the CLI installs and resolves itself (Terraform, TFLint, `avmfix`, …).
- **Managed-file pin** — `<repo>/.avm/managed-files-version.json`. Records the managed-files release a repo is synced against, per §8.
- **Module context** — the `pscustomobject` returned by `Get-AvmModuleContext` describing a Bicep or Terraform module's root, ecosystem, scope, and owner.
- **Public verb** — a verb exposed to end users via the `avm` dispatcher and the approved-verb cmdlets. Every public verb is in §4 of the plan.
- **Tier 1 / Tier 2** — OS support tiers defined in §2.
- **Repo-local state** — anything written under `<repo>/.avm/` per §8.
- **User state** — anything written under the per-user folders per §7.

---

## 25. References

- [avm-consolidation-plan.md](avm-consolidation-plan.md) — the phased plan this spec implements.
- [quality-standards.md](quality-standards.md) — cross-cutting standards and traps that apply everywhere in this spec.
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
