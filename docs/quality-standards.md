# Quality standards

Cross-cutting engineering standards that have shaped (and continue to shape) the `Avm.Authoring` module. The spec ([`avm-implementation-spec.md`](avm-implementation-spec.md)) is still the authoritative source for **what to build**. This file is the authoritative source for **the rules and traps you have to know about while building it** — the things every slice has to honour, the gotchas that bit a previous session, and the post-incident guards that must never be loosened.

If the spec says one thing and this file says another, the spec wins. If this file says something the spec doesn't cover, it's still binding — these are lessons learned the hard way and they belong somewhere accessible.

Read this file:

- Before you write or refactor anything under `src/`.
- Before you add a new linter exclusion, change `.gitattributes`, or touch the build pipeline.
- Whenever PSScriptAnalyzer or Pester behaves in a way that surprises you — the answer is probably already below.

> See also: [`avm-implementation-spec.md`](avm-implementation-spec.md) for engineering rules; [`avm-consolidation-plan.md`](avm-consolidation-plan.md) for scope and sequencing; [`progress.md`](progress.md) for the live status checklist.

---

## 1. File encoding

**Rule.** Every text file in `src/` is **UTF-8 without BOM** with **LF** line endings, regardless of OS. Same applies repo-wide for `.ps1`, `.psm1`, `.psd1`, `.md`, `.yml`, `.yaml`, `.json`, `.toml`, `.sh`, `.bicep`, `.tf`, `.hcl`.

**Enforcement.**

- `.gitattributes` declares `* text=auto eol=lf` plus per-extension overrides (`*.ps1 text eol=lf working-tree-encoding=UTF-8`, …). This handles checkouts on Windows where `core.autocrlf` would otherwise mangle on write.
- `tests/Pester/Unit/Module/Encoding.Tests.ps1` walks every relevant extension under `src/` and fails the build if any file contains a BOM (`0xEF 0xBB 0xBF`) or any `0x0D` (CR) byte. Failure message names every offending path so you can fix in one pass.

**If you see CRLF warnings from `git status`,** fix the file — don't fight `core.autocrlf`. Common cause: pasting from a Windows editor that auto-converted on save, or a sparse-checkout from upstream done without `core.autocrlf=false`.

> See also: [`avm-implementation-spec.md` §5](avm-implementation-spec.md#5-powershell-coding-standards).

---

## 2. Cross-OS rules

The module is **Tier 1** on Windows, Linux, and macOS. PS 7.4+ Core only — no Windows PowerShell 5.1 paths anywhere.

**Paths.** Always treat the filesystem as case-sensitive, even on NTFS and APFS. The 2026-05 publishing incident is the canonical lesson (covered in §9 below). In code:

- Join segments with `Join-Path` or `[System.IO.Path]::Combine(...)`, never with string concatenation and a literal `/` or `\`.
- Use `[System.IO.Path]::PathSeparator` and `[System.IO.Path]::DirectorySeparatorChar`, never hardcoded `;`/`:` or `\`/`/`.
- Use `$HOME` for the user's home directory (works on every OS), not `$env:USERPROFILE` (Windows-only) or `$env:HOME` (POSIX-only).
- Use `[System.IO.Path]::GetTempPath()` for temp, not `$env:TEMP` or `/tmp`.
- Branch on `$IsWindows` / `$IsLinux` / `$IsMacOS` (built into PS 7), not on parsed `[Environment]::OSVersion` strings.
- Branch on `[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture` for amd64 vs arm64.

**OS-specific directories.** Use `Get-AvmFolder` (`Config` / `Cache` / `Data` / `State` / `Tools` / `Logs`). It honours the `AVM_HOME` override, XDG on Linux, Apple's standard directories on macOS, and Windows Known Folders. Do not paste OS branches into individual cmdlets.

**Path length.** Keep generated paths well under 260 characters even when Windows long-path support is enabled. Use the first 12 hex of a SHA256 where a content-addressed segment is needed, not the full 64.

**Symlinks and the executable bit.** The module **does not create** symlinks. It **may follow** them when set up by the user. On non-Windows, after extracting a downloaded binary, set the executable bit with `chmod +x` via `Invoke-AvmProcess` — don't shell out to bash.

**Console encoding on Windows.** The module forces `[Console]::OutputEncoding` and `$OutputEncoding` to UTF-8 at import time on Windows so subprocess stdout/stderr from `terraform`/`tflint`/`bicep`/`conftest` decode cleanly. Set `$env:AVM_NO_CONSOLE_CONFIG = '1'` **before** `Import-Module Avm.Authoring` to opt out. Linux/macOS use UTF-8 natively — no encoding setup runs on those platforms regardless of the env var. Mechanism lives in the top-of-file `if` block in `src/Avm.Authoring/Avm.Authoring.psm1`.

**Case-collision canary.** `tests/Pester/Unit/Module/CaseCollision.Tests.ps1` runs on Linux only and validates the resolver doesn't silently pick the wrong file when two paths differ only in casing. Don't remove the Linux-only gate — Windows and macOS filesystems hide the bug.

> See also: [`avm-implementation-spec.md` §6](avm-implementation-spec.md#6-os-agnostic-path-and-filesystem-rules), [`avm-implementation-spec.md` §7](avm-implementation-spec.md#7-os-specific-paths-and-files).

---

## 3. Subprocess invocation

**Rule.** Every subprocess launch goes through `Invoke-AvmProcess`. Argv arrays only. No `cmd /c`, no `bash -c`, no `Invoke-Expression`, no `Start-Process` with a single command string, no string-concatenated command lines.

**Why.** The CLI orchestrates external tools (`terraform`, `tflint`, `terraform-docs`, `conftest`, `bicep`, …) on every public verb. A string-built command line breaks the moment a path contains a space, an `&`, a `'`, a `"`, or any character the host shell parses specially. argv arrays bypass shell parsing entirely; the OS sees the program plus N pre-tokenised arguments.

**Contract.** `Invoke-AvmProcess`:

- Takes `-FilePath` (the binary) and `-ArgumentList` (the argv array, **not** a string).
- Splits stdout and stderr; returns a `pscustomobject` with `ExitCode`, `StdOut`, `StdErr`, `Duration`.
- Supports `-WorkingDirectory`, `-EnvVars` (override env for the child only), `-Timeout`, `-IgnoreExitCode` (return the record on non-zero rather than throwing).
- On non-zero exit and no `-IgnoreExitCode`, throws `AvmProcessException` carrying the captured stderr in the message.

**Pattern.** Every wired engine follows this shape; copy it:

```powershell
$tool = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback
$args = @('fmt', '-recursive', '-list=true', '-write=true', $Context.Root)
$result = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList $args -WorkingDirectory $Context.Root
```

`Invoke-AvmProcess` is not in tests' way — Pester unit tests mock it with `Mock Invoke-AvmProcess { ... }` and assert the argv array via `-ParameterFilter`.

> See also: [`avm-implementation-spec.md` §9](avm-implementation-spec.md#9-subprocess-invocation), [`avm-implementation-spec.md` §17](avm-implementation-spec.md#17-security).

---

## 4. PowerShell coding standards

**Every public function starts with:**

```powershell
function Invoke-AvmThing {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param( ... )
    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }
    process {
        # ...
    }
}
```

Drop `SupportsShouldProcess` on read-only cmdlets. Keep `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` in `begin` on every public cmdlet — the linter (see §5) requires the `begin {}` block when a parameter declares `ValueFromPipeline`.

**Naming.**

- Approved verbs only (`Get-Verb`). Build fails if `PSUseApprovedVerbs` flags any.
- `Avm` prefix on every exported function noun (`Invoke-AvmPreCommit`, `Get-AvmModuleContext`, `Install-AvmTool`).
- Private helpers follow the same `Avm` prefix.
- Parameters are PascalCase, no abbreviations (`-Module`, not `-Mod`).

**Style.**

- 4-space indent, no tabs.
- One statement per line.
- Always brace single-line `if`/`foreach`.
- No aliases in module code (`Get-ChildItem`, not `gci`). Enforced by `PSAvoidUsingCmdletAliases`. Tests and one-off scripts may use them.
- No positional cmdlet calls in module code; named parameters everywhere.

**File layout.** One cmdlet per file in `Public/` and `Private/`; file basename matches the function name exactly (case-sensitive on disk). Tests mirror the source tree: `Public/Invoke-AvmPreCommit.ps1` ↔ `tests/Pester/Unit/Public/Invoke-AvmPreCommit.Tests.ps1`.

> See also: [`avm-implementation-spec.md` §5](avm-implementation-spec.md#5-powershell-coding-standards), [`avm-implementation-spec.md` §13](avm-implementation-spec.md#13-public-api-surface).

---

## 5. PSScriptAnalyzer

**Settings.** `src/Avm.Authoring/Resources/PSScriptAnalyzerSettings.psd1`. The `lint` Invoke-Build task runs `Invoke-ScriptAnalyzer -Path src/ -Settings <path> -CustomRulePath <path>` and treats `Warning` and above as fixable, `Error` as blocking.

**Custom rule: `AvmAvoidStringThrow`.** Lives at `src/Avm.Authoring/Resources/CustomRules/AvmAvoidStringThrow.psm1`. Flags `throw 'literal'` and `throw "expandable $var"` at `Warning` severity. Allows the canonical `throw [Type]::new(...)`, bare `throw` re-throws, and variable throws (`throw $_`, `throw $exception`).

- The rule body gates on `$ScriptBlockAst.Parent -eq $null` so each throw is reported exactly once when `FindAll(..., $true)` walks descendants. Without that gate, PSSA's per-`ScriptBlockAst` invocation reports throws nested inside functions twice — once for the file SBA, once for the function-body SBA.
- Returns `[Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{ RuleName = 'AvmAvoidStringThrow'; Severity = 'Warning'; ... }` via the hashtable-cast pattern.

**Transient `NullReferenceException` mitigation.** PSScriptAnalyzer occasionally throws `NullReferenceException` from `AnalyzeScript` in a way that doesn't reproduce on a re-run. The `lint` task wraps `Invoke-ScriptAnalyzer` in `Invoke-ScriptAnalyzerWithRetry` (`build/avm.build.ps1`) which retries up to `$env:AVM_LINT_MAX_ATTEMPTS` (default 3) times before giving up. If lint ever crashes locally with `Object reference not set to an instance of an object.` and re-running passes, that's the symptom — don't go hunting for the cause unless it becomes reproducible.

**Cross-platform consumer wrap.** `Invoke-ScriptAnalyzer` returns nothing (pipeline `$AutomationNull`) on Linux/macOS when there are zero findings. Under `Set-StrictMode -Version 3.0`, `$records.Count` then throws `PropertyNotFoundException: The property 'Count' cannot be found on this object`. Wrap consumer-side call sites with `@(...)` so the result is always an array:

```powershell
$records = @(Invoke-ScriptAnalyzer -Path $file -Settings $settings)
if ($records.Count -gt 0) { ... }
```

The `BeforeAll` helper can `return @($records)` but PowerShell unrolls array returns from functions, so array semantics have to be re-established at the consumer. This bit `tests/Pester/Unit/Module/AvmAvoidStringThrow.Tests.ps1` 9 times in the same slice; it'll bite again.

**Two well-known rule conflicts.**

- **`PSUseConsistentWhitespace` ↔ `PSAlignAssignmentStatement`** are mutually exclusive in their default forms. `PSAlignAssignmentStatement` wants `$foo    = 1; $foobar = 2`; `PSUseConsistentWhitespace` wants exactly one space around `=`. Pick one and disable the other in the settings file — both can't be on.
- **`PSUseProcessBlockForPipelineCommand`** requires an explicit `begin {}` block around `Set-StrictMode -Version 3.0` when the function has `[Parameter(ValueFromPipeline)]`. Putting the strict-mode setup at the top of `process {}` instead trips the rule.

**Known historical crash.** A `function script:Foo { … }` nested inside another function once crashed PSScriptAnalyzer with `NullReferenceException` in a 2026-05 session. Not currently reproducing; the retry wrapper above handles it if it returns.

> See also: [`avm-implementation-spec.md` §14](avm-implementation-spec.md#14-error-handling), [`avm-implementation-spec.md` §19](avm-implementation-spec.md#19-static-analysis-and-pre-commit).

---

## 6. Pester 5 traps

Pester 5.5+ only; no Pester 4 syntax anywhere. `Describe` / `Context` / `It`.

**`<word>` placeholder collision in `It` titles.** Pester 5 interprets any `<word>` substring inside an `It` title as a `-TestCases` variable placeholder. At run time it tries to expand `$word` and throws `RuntimeException: The variable '$word' cannot be retrieved` if the variable isn't bound to a `-TestCases` row. The trap only manifests at run time, not at discovery — local Windows can pass while CI fails.

- **Bad.** `It 'appends each examples/<name>/exceptions/*.rego as additional --policy pairs'`
- **Good.** `It 'appends each examples/{name}/exceptions/*.rego as additional --policy pairs'`

Use curly-brace placeholders (or any other shape) in titles that need to show a parameterised path; reserve `<word>` for actual TestCases bindings.

**Auto-variable collisions.** Pester's `It` blocks have a handful of automatic variables that quietly shadow user code:

- `$matches` — Pester's regex-match capture. Don't name a local variable `$matches` if you also use `-match` in the same block, and don't rely on `$matches` set outside `It` carrying into it.
- `$eventArgs` — Pester's event handler payload. Same hygiene.

When you need to capture regex matches from a `Where-Object` loop inside an engine, name the local `$exceptionMatches` (or any other unambiguous name) rather than letting it land on `$matches`.

**`BeforeAll` array unrolling.** A `BeforeAll { return @($records) }` returns the array to Pester, but PowerShell unrolls single-element arrays returned from functions. Re-wrap with `@(...)` at the consumer in `It` blocks if you need array semantics on a single-element collection.

**Strict-mode 3.0 property access on `pscustomobject`.** `$obj.PropertyThatDoesNotExist` throws `PropertyNotFoundException` under strict-mode 3.0. Use `$obj.PSObject.Properties[$name]` to test for property existence:

```powershell
if ($obj.PSObject.Properties['Children']) { $obj.Children }
```

**Strict-mode 3.0 `$null` indexing.** `$arr[0]` throws when `$arr` is `$null` — relevant when an upstream call returns `$AutomationNull` (see §5). `@($arr)[0]` is safe.

> See also: [`avm-implementation-spec.md` §18](avm-implementation-spec.md#18-testing).

---

## 7. Networking

**Rule.** Every HTTP call goes through `Invoke-AvmHttp` in `Private/Http/`. HTTPS-only. SHA256 verify mandatory.

**What `Invoke-AvmHttp` enforces.**

- TLS 1.2 minimum, 1.3 preferred. Set at module load:

  ```powershell
  [System.Net.ServicePointManager]::SecurityProtocol =
      [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
  ```

- `User-Agent: Avm.Authoring/<version> (<os>/<arch>)` header on every request.
- 60-second default timeout (overridable).
- Retries on 5xx and connection errors with exponential backoff (3 attempts, 1 s / 4 s / 16 s).
- Honours proxy env vars (`HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`) via the native `Invoke-WebRequest` plumbing.
- Verifies the certificate chain. **Never** use `-SkipCertificateCheck`. Ever.
- SHA256 verifies every download against the lock entry or pinned-asset descriptor. Mismatch throws `AvmToolException` with both expected and actual hashes in the message. Partial files are cleaned up on hash mismatch so the next attempt isn't poisoned by garbage on disk.

**`AVM_OFFLINE`.** When set to `'1'`, the resolver refuses any HTTP traffic. Cache hits succeed; cache misses fail fast with a clear message naming the missing tool. Test fixtures use `file://` URLs that bypass `AVM_OFFLINE` so the offline path stays testable.

**`AVM_MIRROR`.** When set, every `urlTemplate` is rewritten before download. The mirror's scheme, authority, and path prefix are preserved; the source URL's path-and-query is appended verbatim. The mirror itself **MUST** be `https://` — an `http://` mirror is refused with `AvmConfigurationException` so a misconfigured proxy can't silently downgrade TLS. `file://` source URLs (test fixtures) are never rewritten.

**Tool binary supply chain.** Pinned in `src/Avm.Authoring/Resources/tools.lock.psd1`. The lock file is the only sanctioned source of truth for SHA256s. `scripts/Update-AvmToolsLock.ps1` is the only sanctioned path to rotate a hash; the PR that lands the rotation records what was updated and which upstream release notes were reviewed. No precompiled binaries in the repo — everything is fetched at first use and cached under `Get-AvmFolder Tools`.

> See also: [`avm-implementation-spec.md` §10](avm-implementation-spec.md#10-tool-resolver-and-cache), [`avm-implementation-spec.md` §16](avm-implementation-spec.md#16-networking), [`avm-implementation-spec.md` §17](avm-implementation-spec.md#17-security).

---

## 8. Test layering

Three layers; each runs with its own tag filter.

| Layer       | Folder                       | Network | Filesystem | Default? |
| ----------- | ---------------------------- | ------- | ---------- | -------- |
| Unit        | `tests/Pester/Unit/`         | No      | No (mocks) | Yes      |
| Integration | `tests/Pester/Integration/`  | No      | Real (under `TestDrive`); stub binaries via `tests/fixtures/bin/`  | Opt-in via `./build.ps1 integration`   |
| Smoke       | `tests/Pester/Smoke/`        | Yes (pulls one real managed tool from the resolver) | Real | Opt-in via `-Tag Smoke`; release-branch CI only |

**Local gate.** `./build.ps1 pre-commit` chains `layout, lint, test`. The `test` task excludes Smoke and Integration via `Filter.ExcludeTag = @('Smoke', 'Integration')`. Run this before every push.

**Stub binaries.** `tests/fixtures/bin/*.ps1` (`terraform.ps1`, `tflint.ps1`, `terraform-docs.ps1`, `conftest.ps1`) emit canned output and exit with intentional codes. Each stub honours `--version` so `Find-AvmToolOnPath`'s semver regex passes. `Install-AvmStubLauncher.ps1` wires the stub into a temp `$env:PATH` for the Integration tier. Anything else exits `64` with stderr so an unexpected argv shape fails loudly.

**Pre-staging the pinned-asset cache.** Integration tests that exercise pinned-asset-backed engines write `<AVM_HOME>/cache/assets/<name>/<sha256>/.verified` (empty file) plus the asset payload, then declare a matching `https://example.invalid/...` source URL with a deterministic-but-fake SHA256 in the fixture's `.avm/config.json`. The cache-hit fast-path in `Resolve-AvmPinnedAsset` short-circuits the entire `Invoke-AvmHttp` download, so no real network is touched and the test stays in the Integration tier.

**Coverage.** 70% line coverage on `src/Avm.Authoring/` minimum, enforced via Pester `CodeCoverage`. CI build fails below the floor. Tracked per file; new files start at the floor and ratchet up as code matures.

**CI matrix.** Every PR runs Unit + Integration on `windows-2025` (x64), `ubuntu-24.04` (x64), `ubuntu-24.04-arm` (arm64), `macos-15` (arm64). Smoke runs once per release on each.

> See also: [`avm-implementation-spec.md` §18](avm-implementation-spec.md#18-testing), [`avm-implementation-spec.md` §19](avm-implementation-spec.md#19-static-analysis-and-pre-commit).

---

## 9. Manifest casing post-incident guard

The 2026-05 publishing incident is the canonical case-sensitivity lesson. **NTFS preserves casing across delete-and-recreate**: renaming a file or folder via "delete then recreate with new casing" silently does nothing on Windows. `Test-Path`, `Test-ModuleManifest.Name`, and `Resolve-Path` are all case-insensitive on NTFS and APFS, so none of them can be used to assert casing. `Publish-PSResource` derives the .nuspec `<id>` from on-disk file casing, **not** from the manifest `Name` field. The wrong casing on disk ships the wrong package id.

**Locked names.** `Avm.Authoring/` (folder), `Avm.Authoring.psd1` (manifest), `Avm.Authoring.psm1` (module file), manifest `Name = 'Avm.Authoring'`, manifest `RootModule = 'Avm.Authoring.psm1'`. All five must match each other **case-sensitively**. Do not loosen these guards.

**Guard.** `Test-AvmModuleLayout` (`src/Avm.Authoring/Private/Layout/`):

- Resolves the module folder via `Split-Path -Leaf` and asserts `-ceq` against the expected name.
- Lists the folder via `Get-ChildItem` and asserts the `.psd1` and `.psm1` files are present **with the exact expected casing** via `Where-Object { $_.Name -ceq $expected }`.
- Parses the manifest and asserts `Name -ceq $expected` and `RootModule -ceq "$expected.psm1"`.
- Runs before every `Publish-PSResource` call in `scripts/Publish-AvmAuthoring.ps1`.
- Surfaces as the `layout` Invoke-Build task so `./build.ps1 pre-commit` exercises it on every contributor run.
- Has its own Pester test that builds a fake module folder with a deliberately mis-cased file and asserts the guard throws.

**To change the casing of a folder or file on Windows,** rename to a different intermediate name first, then to the desired casing:

```powershell
Move-Item Avm.Authoring _tmp
Move-Item _tmp Avm.Authoring
```

> See also: [`avm-implementation-spec.md` §12](avm-implementation-spec.md#12-module-manifest-rules-post-incident).

---

## 10. Error handling

**Every public function:** `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` in `begin`.

**Terminating errors** use `throw [<SpecificException>]::new(<message>, <innerException>)`. Generic `throw "string"` is reserved for prototype code and is flagged by the `AvmAvoidStringThrow` PSSA custom rule (§5). Bare `throw` re-throws are allowed; `throw $_` and `throw $exception` are allowed.

**Typed exception hierarchy** in `src/Avm.Authoring/Private/Exceptions/`:

- `AvmException` — base; carries a stable string error code (`AVM1014`, etc.).
- `AvmConfigurationException` — bad config, missing required env var, missing pinned-asset descriptor. **Composition chains catch this and mark the step `skipped`** (by design — a verb that throws `AvmConfigurationException` is reporting "I'm not configured to run", not "I failed").
- `AvmToolException` — tool resolver / install / SHA mismatch.
- `AvmProcessException` — subprocess exited non-zero; includes captured stdout / stderr.
- `AvmContextException` — repo context resolver couldn't classify the path.

**Stable error codes.** Each exception type carries an `ErrorCode` string the dispatcher echoes in its `--json` error output. Don't rename codes — downstream consumers grep for them. Add new ones at the next free slot in the appropriate range.

**Exit codes from the dispatcher.**

- `0` — success.
- `1` — user error (bad args, bad config, expected condition).
- `2` — internal / unexpected error.
- `10–19` — reserved for the `tool` verb tree.
- `20–29` — reserved for the `test` verb tree.
- `30–39` — reserved for `publish` / `release`.

**`--json` mode.** Stdout contains only a single JSON document. All human-readable narration moves to the `Write-Information` stream and is suppressed from stdout. Errors emit a JSON object on stderr: `{ "error": { "code": "...", "message": "...", "details": {} } }`.

> See also: [`avm-implementation-spec.md` §14](avm-implementation-spec.md#14-error-handling), [`avm-implementation-spec.md` §11](avm-implementation-spec.md#11-output-logging-and-streams).

---

## 11. Commit + push protocol

One commit per slice. A "slice" is the unit you just flipped from `[~]` to `[x]` in `docs/progress.md`, or a self-contained doc / refactor that doesn't have its own checkbox.

**Gate.** `./build.ps1 pre-commit` must be green before you commit code changes. Doc-only commits skip the gate.

**Message style.** [Conventional Commits](https://www.conventionalcommits.org/):

- `feat(<area>): …` for new behaviour (`feat(http): honour AVM_MIRROR via Resolve-AvmMirrorUrl helper`).
- `fix(<area>): …` for bug fixes.
- `refactor(<area>): …`, `test(<area>): …`, `docs: …`, `chore: …`, `ci: …` as appropriate.
- First line ≤ 72 chars. Use a body when the *why* isn't obvious from the diff; reference the spec / progress item.

**Trailer.** Every commit ends with:

```text
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

**Staging.** Prefer `git add -A` for slice commits so progress-doc updates land with the code. If you have unrelated dirty files (rare), be explicit instead.

**Push.** `git push origin HEAD:feat/avm-authoring-initial` immediately after the commit. The active feature branch on the remote is `feat/avm-authoring-initial`; your local worktree branch is whatever scrub name the workspace was created with, so push with an explicit `HEAD:feat/avm-authoring-initial` refspec.

- Never `--force`.
- Never push to `main`.

**Failure path.** If `git push` is rejected because the remote moved, `git pull --rebase origin feat/avm-authoring-initial` and re-run `./build.ps1 pre-commit` before retrying the push. Do not force-push to resolve.

**PRs / merges.** Still user-driven. Don't open, merge, or close PRs without explicit instruction.

> See also: [`AGENTS.md`](../AGENTS.md) § Commit & push protocol.

---

## Appendix D. Decision: long-path support on Windows

### Context

Spec [§6](avm-implementation-spec.md) line 219 says "keep all generated paths well below 260 characters even when Windows long-path support is enabled" and line 220 says "use short hashes (first 12 hex of SHA256) where a content-addressed segment is needed, not full hashes". Spec [§23 OQ 6](avm-implementation-spec.md) (line 672) asks whether to force-enable long-path support via an application manifest, document the `HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem!LongPathsEnabled` registry key as a prerequisite, or rely on short paths. The spec's lean is "keep paths short enough that the question doesn't matter".

This appendix (a) measures the actual on-disk paths the module currently emits against the 260-character budget, (b) flags a concrete deviation from §6 line 220 that erodes the headroom, and (c) settles the long-path posture.

macOS and Linux aren't subject to MAX_PATH, so this audit is Windows-only.

### Path budget

Worst-case Windows prefix uses a 20-character SAM username (Windows local-account limit):

- `C:\Users\<sam-max-20-char>\AppData\Local\Avm\` = 47 chars
- Plus `Cache\assets\` (the deepest subtree) = 60 chars
- Add a 30-char asset name → 91 chars before the content-addressed segment

Two cache layouts produced by the module today:

| Layout         | Path shape                                                         | Worst-case leaf example                                                                          | Length | Headroom (260 − x) |
| -------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ | ------ | ------------------ |
| Tool cache     | `%LOCALAPPDATA%\Avm\Tools\<tool>\<version>\<binary>`               | `…\Avm\Tools\terraform-docs\0.20.0\terraform-docs.exe`                                           | ~92    | ~168               |
| Tool cache     | same                                                               | `…\Avm\Tools\avm-mapotf-pre-commit\1.99.0\avm-mapotf-pre-commit.exe`                             | ~108   | ~152               |
| Asset cache    | `%LOCALAPPDATA%\Avm\Cache\assets\<name>\<sha256>\<sub-path>`       | `…\Cache\assets\avm-mapotf-configs-pre-commit\<64-hex>\mapotf-configs\pre-commit\avm_headers_for_azapi.mptf.hcl` | **204** | **56**             |
| Asset cache    | same, but with spec-compliant 12-hex segment                       | same with `<12-hex>` in place of `<64-hex>`                                                      | 152    | 108                |
| Staging dir    | `%LOCALAPPDATA%\Avm\Cache\assets\<name>\.staging\<12-char-guid>\…` | …same `mapotf` content path under `.staging\<guid>\`                                             | ~161   | ~99                |
| Log file       | `%LOCALAPPDATA%\Avm\Logs\<iso8601>.log`                            | `…\Avm\Logs\20260605T123045Z.log`                                                                | ~70    | ~190               |

Tool cache is comfortable. Logs are comfortable. Staging directory is comfortable (uses a 12-char GUID already). **Asset cache is uncomfortably tight** — a 56-char margin doesn't survive a single extra layer of nesting inside a bundle. A 4-level-deep path inside a bundle, a 30-char filename, and a 25-character asset name would consume 100+ chars by themselves and put the total past 260.

### Finding (concrete spec deviation)

`src/Avm.Authoring/Private/Assets/Resolve-AvmPinnedAsset.ps1` line 127 uses the **full 64-char SHA256** for the content-addressed segment:

```powershell
$versionDir = Join-Path $assetDir $sha   # $sha is 64 hex chars
```

This violates spec §6 line 220 ("first 12 hex of SHA256, not full hashes"). For comparison, `src/Avm.Authoring/Private/Tools/Install-AvmToolFromLock.ps1` (line 46) correctly avoids hash segments entirely — it uses `<DataDir>/tools/<tool>/<version>/<binary>` because tool installs are version-addressed, not content-addressed. The staging directory (`Install-AvmToolFromLock.ps1` line 109) already uses a 12-character GUID, so the precedent for short identifiers is already in the codebase.

A short hash buys 52 chars of headroom on every asset path, which is roughly the difference between "uncomfortable" and "comfortable" for the realistic mapotf bundle.

Collision-resistance check on the 12-hex truncation: 48 bits of entropy. For asset cardinality below 16M the birthday-bound collision probability is below 0.5 %. Current bounded asset count: 5 (APRL, AVMSEC, mapotf-pre-commit, avmfix-equivalent, plus future). Six-plus orders of magnitude of headroom. Safe.

### Options

(a) **Force-enable long-path support via an application manifest.** Caveats:
- PowerShell 7.4+ on Windows ships with a long-path-aware host manifest (`pwsh.exe.config` sets `<longPathAware>true</longPathAware>`). Inherited automatically — no module work needed.
- This still requires Windows 10 1607+ **and** `LongPathsEnabled=1` in the registry. On older Windows or systems without the registry key, paths still fail at 260 regardless of any manifest.
- PowerShell module manifests (`.psd1`) cannot carry a long-path opt-in; the runtime's manifest applies.
- Effectively the same as option (b) — "documented prerequisite" wearing different clothes.

(b) **Document `New-ItemProperty -Path 'HKLM:\…\FileSystem' -Name LongPathsEnabled -Value 1` as a prerequisite.** Lowest implementation cost (one paragraph in CONTRIBUTING.md). Pushes the problem onto users. Requires Administrator for HKLM. High risk of silent failures on machines where the user can't or didn't run it.

(c) **Comply with spec §6 line 220 — switch the asset cache to a 12-hex SHA segment.** Small, focused code change in `Resolve-AvmPinnedAsset.ps1`. Adds ~50 chars of headroom across all asset paths. Doesn't depend on Windows version, doesn't require admin, doesn't require the user to do anything. The tool cache already complies. Single-pass cache rebuild on the user side (existing `.verified` markers gate it; old 64-hex dirs become orphan and can be GC'd by a future cleanup verb or just left until the user wipes the cache).

### Recommended option: (c) — comply with spec §6 line 220. Defer (a)+(b) until measurement shows they're needed.

Reasoning:

1. (c) is the cheapest path **and** the spec-compliant one. Three lines of code change in `Resolve-AvmPinnedAsset.ps1`, plus a handful of test assertions.
2. (a) and (b) only help in the band between 260 and the NTFS hard limit (~32 767 chars). Long-path enablement is irrelevant outside that band. With (c) we don't cross 260 for any realistic asset on any realistic Windows user account.
3. (a) and (b) push the failure mode out of our control (per-machine config, admin permission, Windows version). (c) keeps the contract self-contained.
4. PowerShell 7.4+'s own long-path manifest is a pre-existing safety net for the `Cache\assets\…` paths we emit — but it depends on registry state we don't own. Don't rely on it.
5. The spec's lean ("keep paths short enough that the question doesn't matter") is achievable today. Adopting (c) means OQ 6 resolves to "neither (a) nor (b); paths are short enough".

### Slice implementation outline (separate, deferred — tracked as a follow-up)

The implementation is a small focused slice that the next autopilot session can pick up; this appendix only delivers the decision, not the code change.

`src/Avm.Authoring/Private/Assets/Resolve-AvmPinnedAsset.ps1`:

1. Compute the short hash: `$shortSha = $sha.Substring(0, 12)`.
2. Replace `$versionDir = Join-Path $assetDir $sha` with `Join-Path $assetDir $shortSha`.
3. Keep storing the full 64-hex SHA in `.meta.json` so traceability and integrity verification aren't affected (`.meta.json` is parsed, not part of any path).
4. Adjust the doc-comment example accordingly.

Tests under `tests/Pester/Unit/Private/Assets/Resolve-AvmPinnedAsset.Tests.ps1`:

- Update existing path-shape assertions: expect a 12-char hex segment, not 64.
- Add a regression: `.meta.json` round-trip preserves the full SHA.
- Add an explicit length assertion on a realistic worst-case input so the cap doesn't silently regress (suggested cap: 200 chars).

Documentation: add a one-line cross-reference under the spec §6 quote at the top of this appendix once the slice lands.

### Open follow-ups

1. **Slice K** (suggested ID): execute recommendation (c) above. Autopilot-safe — design has been signed off via this audit.
2. Optional belt-and-braces: a Pester test under `tests/Pester/Unit/Module/` that emits a representative worst-case path through `Get-AvmFolder` + `Resolve-AvmPinnedAsset` and asserts the result is below a fixed budget (suggest 200 chars, 60 below MAX_PATH). Slot in alongside the existing layout tests.

### Deliberately deferred

- **Application-manifest opt-in for a future shipped wrapper** (e.g. a `dotnet tool` per spec §23 OQ 5). Re-evaluate when OQ 5 is resolved; until then the host runtime's manifest is what matters.
- **Stale-cache GC verb** (`avm cache clean` or similar). Old 64-hex asset directories will linger on user machines after Slice K lands. They're harmless (just disk use). Track as a separate Phase 3 polish slice.
- **Cross-volume cache redirection** (e.g. `AVM_HOME` on a deeper-than-`%LOCALAPPDATA%` drive). Users who do this already opt into longer paths; document the budget under the existing `AVM_HOME` documentation when Slice K lands. Not a blocker for the recommendation.

## Appendix A. Decision: `grept` policy disposition

> **Status:** Audit landed 2026-06-04 (Slice B of the Terraform-first pivot plan).
> **Upstream snapshot reviewed:** [`Azure/avm-terraform-governance@65182443`](https://github.com/Azure/avm-terraform-governance/tree/65182443/grept-policies).
> **Why this lives here:** the [consolidation plan §10 Phase 4](avm-consolidation-plan.md#10-phase-by-phase-delivery) treats `grept` as REPLACED, not selectively ported. This appendix records the per-policy disposition that drives Slice C's primitive set and Slice D's port list, so future agents don't re-litigate the decisions.

### Context

`grept` is invoked by the upstream `pre-commit.porch.yaml` in a single `grept apply -a "$AVM_GOVERNANCE_REPO_DIR/grept-policies"` step that runs **all 7 policies together**, with one environment escape (`$AVM_GREPT_SKIP`). There is no per-policy on/off. Every disposition below is therefore a binary choice for the new `avm check convention` chain: implement (and how), or drop.

The 7 policies actually present at the audit SHA:

```text
deprecated_files.grept.hcl
ensure_dir_existence.grept.hcl
ensure_file_existence.grept.hcl
git_ignore.grept.hcl
managed_files.grept.hcl
outputs_tf.grept.hcl
variables_tf.grept.hcl
```

(The [plan §4 Slice B](../plan.md) listed `required_files.grept.hcl`; the actual upstream filename is `ensure_file_existence.grept.hcl` — same intent, just renamed.)

### Per-policy disposition

| # | Policy file                       | Concretely asserts (and what its `fix` block does)                                                                                                                                                                                                                                                                            | Already covered elsewhere?                                                                                                              | Disposition       | Primitive needed in Slice C                | Rationale                                                                                                                                                                                                                                                                                                                                                                                                                          |
| - | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | `outputs_tf.grept.hcl`            | `output.tf` must NOT exist. Fix: `rename_file` `output.tf` → `outputs.tf`.                                                                                                                                                                                                                                                    | No. Terraform itself is filename-agnostic; `terraform-docs` doesn't care; our `Test-AvmModuleLayout` only guards `src/Avm.Authoring/`. | **PS rule**       | `FileMustNotExist` (+ optional rename fix) | AVM spec mandates plural `outputs.tf`; the singular form is a frequent contributor mistake. Cheap, deterministic, no upstream churn.                                                                                                                                                                                                                                                                                              |
| 2 | `variables_tf.grept.hcl`          | `variable.tf` must NOT exist. Fix: `rename_file` `variable.tf` → `variables.tf`.                                                                                                                                                                                                                                              | No (same coverage gap as #1).                                                                                                           | **PS rule**       | `FileMustNotExist` (reused from #1)        | Same shape and rationale as #1. Reuses the same primitive — no extra Slice C surface.                                                                                                                                                                                                                                                                                                                                              |
| 3 | `ensure_file_existence.grept.hcl` | `terraform.tf` and `_header.md` must exist. Fix: writes empty content (`""`).                                                                                                                                                                                                                                                | No. Terraform tolerates `terraform { }` in any file; `terraform-docs` *uses* `_header.md` if present but doesn't *require* it.          | **PS rule**       | `FileMustExist`                            | `terraform.tf` is the canonical home for the `terraform` block (required\_version + required\_providers) per AVM; `_header.md` feeds `terraform-docs` injection. Keep the assertion; **drop the empty-file fix** — emit a violation and let the user (or future `avm new`) author real content. Auto-creating empty files is brittle and the empty `terraform.tf` is itself an AVM violation.                                          |
| 4 | `ensure_dir_existence.grept.hcl`  | `examples/` and `tests/` directories must exist. Fix: creates `examples/.gitkeep` and `tests/.gitkeep`.                                                                                                                                                                                                                       | No.                                                                                                                                     | **PS rule**       | `DirectoryMustExist`                       | Both dirs are core to the AVM workflow (`examples/` drives per-example pre-commit + `terraform-docs`; `tests/` houses `terraform test`). Keep the assertion; **drop the `.gitkeep` fix** — both fixtures we ship have non-empty `examples/` and `tests/`, so Git preserves the dirs naturally; emitting `.gitkeep` litters the repo for a one-time setup problem.                                                                |
| 5 | `git_ignore.grept.hcl`            | `.gitignore` must contain a specific set of 24 globs (state, plans, lockfiles, `.terraform/`, tfvars, `.DS_Store`, `crash.log`, `.avm`, etc.). Fix: appends missing entries via `git_ignore` fix block.                                                                                                                       | No. `.gitattributes` controls EOL/encoding, not what's tracked.                                                                         | **PS rule**       | `GitignoreMustContain`                     | High-value: the difference between accidentally committing 50 MB of `.terraform/providers/` (or worse, `secret.tfvars`) and not. Keep the assertion *and* the append-missing-globs fix — both are safe and idempotent. The 24-glob set should ship as the rule's default `RequiredGlobs` parameter (overridable per-module if anyone ever needs to).                                                                                |
| 6 | `deprecated_files.grept.hcl`      | 17 paths must NOT exist; mostly upstream-workflow renames (`.github/workflows/{e2e,grept_cronjob,linting,version-check}.yml`, `.github/actions/version-check/`, `.github/policies/avmrequiredfiles.yml`, `.vscode/mcp.json`) plus skill-folder renames (`.agents/skills/AVM-Terraform-Development/*`) plus `locals.telemetry.tf` and `locals.version.tf.json`. Fix: `rm_local_file`. | The legacy shim (`avm`, `avm.bat`, `avm.ps1`, `Makefile`) is documented as a removal step in [`migration-terraform.md`](migration-terraform.md). | **Drop (mostly)** | None                                       | Most of this list is *upstream housekeeping* (workflow renames, skill-folder renames) that has no AVM-contract bearing — porting it forces every consumer to mirror the governance repo's internal refactors. The legitimate "delete the legacy shim" sub-case is already covered by the migration guide and only matters during one-shot migration, not on every pre-commit. **Net: no rule in `avm check convention`.** A future opt-in `avm migrate terraform` verb could carry the shim-removal, but it does not belong in the per-commit chain. |
| 7 | `managed_files.grept.hcl`         | Every file under `managed-files/root/` (and optionally `managed-files/<additional>/` for variants like `alz`) must be SHA1-identical in the consumer repo. Fix: overwrites the consumer's copy with the upstream byte-for-byte content.                                                                                       | No — and that's exactly the problem.                                                                                                    | **Drop entirely** | None                                       | Three independent reasons: (1) the bundle ships the **legacy shim itself** (`avm`, `avm.bat`, `avm.ps1`, `Makefile`) plus the GitHub workflows in current flux — locking every consumer to an upstream SHA is exactly the brittle versioning the consolidation is meant to escape; (2) "byte-for-byte SHA1 match" is the wrong shape — the actual AVM contract is *shape* of `.terraform-docs.yml`, *shape* of `.gitattributes`, *presence* of `_header.md` — none of those need byte equality with a specific upstream snapshot; (3) for repo boilerplate (`CODE_OF_CONDUCT.md`, `SECURITY.md`, `SUPPORT.md`, `LICENSE`) GitHub's own community-standards UI is the source of truth — we don't need a rule. If targeted shape rules ever become necessary later (e.g. `terraform-docs config must contain inject mode = inject-html`) they ship as individual rules in the convention framework, not as a bulk byte-match. |

### Slice C primitive set (the only Slice C deliverable that depends on this audit)

After dispositions above, Slice C needs to build exactly **four** primitives, not the seven the plan listed as illustrative:

| Primitive             | Used by | Slice D rule modules (count)                                                                |
| --------------------- | ------- | ------------------------------------------------------------------------------------------- |
| `FileMustNotExist`    | #1, #2  | 2 (one per filename)                                                                        |
| `FileMustExist`       | #3      | 1 (parameterised with `terraform.tf` + `_header.md`, plus optional `description` per file) |
| `DirectoryMustExist`  | #4      | 1 (parameterised with `examples/` + `tests/`)                                              |
| `GitignoreMustContain` | #5      | 1 (parameterised with the 24-glob default set)                                              |

> Slice C **does not** need to build `FileContentMustMatch` / SHA1-of-upstream / file-templating-render primitives. The `managed_files` bundle's behaviour is dropped on purpose; if a future slice ever needs scaffolding it goes into a new `avm new` verb, not into the convention framework.

### Cross-cutting decisions baked in

1. **No bulk byte-match.** The new convention framework asserts shape / presence / line-set membership only. Anything that needs "this whole file should equal an upstream blob" is a smell pointing back at this audit's reasoning.
2. **No auto-`.gitkeep` materialisation.** Both `ensure_dir_existence` and `managed_files` historically wrote empty marker files; the new framework drops both.
3. **Empty-content fixes are violations, not fixes.** `ensure_file_existence` would auto-create empty `terraform.tf` / `_header.md` — that just trades one violation for another. The new rule emits a violation and stops.
4. **Per-module overridability.** Every parameterised primitive (`#3`, `#4`, `#5`) accepts an override in the consumer's `avm.config.json` so site-specific module shapes (e.g. a vendor with no `tests/` discipline) can opt out without forking the rule module.
5. **No new pre-commit step for "delete the legacy shim".** The `deprecated_files` removal of `avm`/`avm.bat`/`avm.ps1`/`Makefile` is one-time migration concern; see [`migration-terraform.md`](migration-terraform.md). Putting it in `avm check convention` would mean every consumer's pre-commit fails until they migrate — wrong shape.

### What is deliberately deferred

- A future opt-in `avm migrate terraform` verb that walks the legacy-shim removal + the `.github/workflows/` rename list. Out of scope for the pre-commit chain.
- A future opt-in `avm new -Ecosystem terraform` scaffolder that emits a known-good starting tree (real `terraform.tf`, real `_header.md`, real `.gitignore`, real `examples/default/main.tf`). Replaces the *useful* half of `managed_files` (the "give me a starting point" half) without the SHA1-lock half.
- Per-module overrides for the `GitignoreMustContain` glob set (mechanism above; default list ships in Slice D).


## Appendix B. Decision: mapotf replacement strategy

> **UPDATE 2026-06-19 — supply-chain UNBLOCKED; recommendation flips from build-and-host to wrap-the-shipping-release. See [Appendix J](#appendix-j-2026-06-19-terraform-pre-commit-ground-truth-refresh) for the authoritative current state.** Three facts changed since this audit was written:
> 1. **`Azure/mapotf` now ships goreleaser releases.** Latest `v0.1.4` (published 2026-06-10) ships the canonical 6-platform archive shape (`mapotf_0.1.4_{os}_{arch}.{tar.gz|zip}` + `checksums.txt`) — identical to `conftest` / `terraform-docs`. The open follow-up #1 below ("confirm mapotf release-shipping status — the 2026-05-27 audit said no") is now **resolved: yes**. The build-and-host hosting decision (follow-up #2) is **moot** — no Azure-side workflow PR needed; we pin the upstream `Azure/mapotf` release directly in `tools.lock.psd1`.
> 2. **mapotf gained ordering/sorting transform primitives.** The per-config audit below predates `reorder_attributes`, `sort_blocks_in_file`, `remove_block_element`, and `move_block`. The live governance bundle is now **nine** configs (not three): `avm_headers_for_azapi`, `main_telemetry_tf`, `move_misplaced_blocks`, `order_module_attrs`, `order_resource_attrs`, `order_resource_meta`, `required_provider_versions`, `sort_outputs`, `sort_variables`. Together they realise the **entire** avmfix 10-behaviour catalogue from Appendix C — including the file-partitioning behaviours #5 + #7 that [Appendix I](#appendix-i-decision-hcl2json-adoption-for-narrow-file-layout-enforcement) was going to cover with `hcl2json`.
> 3. **Recommended option is now: wrap the shipping `Azure/mapotf` release + pin the governance `mapotf-configs/pre-commit` bundle as a pinned-asset.** The "reimplement in PowerShell / `hcledit`" analysis below stands as the reason we don't reimplement — but the build-and-host conclusion is superseded. The Slice G recipe with concrete SHA256s lives in [Appendix J](#appendix-j-2026-06-19-terraform-pre-commit-ground-truth-refresh).
>
> The per-config audit and reasoning below are retained verbatim as the historical record (they explain *why* wrapping beats reimplementing).

**Context.** Upstream `avm-terraform-governance@65182443` invokes `mapotf transform --mptf-dir <pinned> --tf-dir .` (then `mapotf clean-backup --tf-dir .`) against three configs at `mapotf-configs/pre-commit/*.mptf.hcl`. This audit answers, per config: (1) what does it concretely do; (2) is it important to the AVM contract; (3) what is the cheapest replacement (native PowerShell / general CLI / keep upstream via build-and-host); (4) effort. Read it before Slice G (`Invoke-AvmTerraformTransform`).

### Per-config audit

| # | Config | What it concretely does | Important? | Replacement options | Cheapest |
|---|--------|-------------------------|------------|---------------------|----------|
| 1 | `avm_headers_for_azapi.mptf.hcl` (6.4 KB) | (a) Adds or normalises `variable.enable_telemetry` to `bool` / `default = true` / `nullable = false` + the standard description. (b) For every `azapi_resource` + `azapi_data_plane_resource`, rewrites all 4 lifecycle header attributes (`create_headers` / `delete_headers` / `read_headers` / `update_headers`) to inject the AVM User-Agent via a three-state merge: empty → set verbatim; v1-shape string → set verbatim; already mentions `local.avm_azapi_header` → leave alone; otherwise → wrap in `merge(<existing>, ...)`. (c) Same for `azapi_update_resource` but only on `read_headers` + `update_headers`. | **Yes.** AVM telemetry tenet (M5). Without the headers the module makes Azure API calls without the AVM marker, breaking downstream attribution. | (a) PowerShell — needs an HCL parser + manual reimpl of the 3-state merge. (b) `hcledit` — leaf rewrites trivial, dependency ordering + merge synthesis manual. (c) Keep mapotf via build-and-host. | **(c)** |
| 2 | `main_telemetry_tf.mptf.hcl` (7.9 KB) | Re-emits the whole `main.telemetry.tf` shape: helper locals (`valid_module_source_regex`, `fork_avm`, `avm_azapi_headers`, `avm_azapi_header` with `# tflint-ignore`), removes legacy `data.azurerm_client_config.telemetry`, adds/updates `data.azapi_client_config.telemetry`, `data.modtm_module_source.telemetry`, `resource.random_uuid.telemetry`, `local.main_location` (`var.location` if present else `"unknown"`), and the full `resource.modtm_telemetry.telemetry` `tags = merge(...)` payload — all `count`-gated on `var.enable_telemetry`. | **Yes.** Same tenet as #1; the two together form the AVM telemetry contract. Without it the `modtm_telemetry` resource never updates. | (a) PowerShell — easier than #1 (more deterministic templating) but still needs HCL parsing for the legacy-cleanup branch. (b) `hcledit` — feasible; many small invocations + a removal step. (c) Keep mapotf via build-and-host. | **(c)** |
| 3 | `required_provider_versions.mptf.hcl` (1.2 KB) | If `terraform.required_providers.azapi.version` is outside `~> 2.4`, rewrites it. If `terraform.required_providers.random.version` is outside `~> 3.0`, rewrites it. Two attribute writes total. | **Yes**, lower bar than #1 / #2 — a wrong pin still works at runtime, just diverges from AVM standard. | (a) PowerShell — trivial (`terraform-config-inspect` for the read; small regex or `hcledit` for the write). (b) `hcledit` — one-liner per provider. (c) Bundled in with (c) above for free. | **(c)** (or trivially (a)/(b) if standalone) |

### Recommended option: **(c) keep mapotf via build-and-host**

Concrete reasoning:

1. **The two big configs are non-trivial to reimplement.** ~250 lines of HCL across configs #1 + #2, with `for_each`, `try()`, three-state merge synthesis, nested `depends_on` between transforms, and multi-line string templating. PowerShell needs an HCL parser (no mature vendorable option exists; `terraform-config-inspect` only emits structure, not attribute bodies). `hcledit` scripts can do leaf rewrites but the cross-config dependency graph (config #1's `var.enable_telemetry` block must land before config #2's data sources) becomes a hand-maintained shell orchestration.
2. **Configs evolve upstream.** New `azapi_*` resource types, telemetry payload churn, and provider-version drift all happen on `avm-terraform-governance`'s schedule. A verbatim-upstream pin gives us one SHA to bump; a rewrite forks us into perpetual catch-up.
3. **mapotf the tool is small.** `lonegunmanb/mapotf` is ~3k LoC Go. The cost of adding a release workflow once is much less than the cost of reimplementing 3 configs + maintaining them forever.
4. **Config #3 is trivial in any path.** It bundles for free under (c), and inlining it as an `hcledit` two-liner stays viable if (c) ever falls through. Doesn't change the recommendation.

### Slice G implementation outline (if option (c) holds)

`Invoke-AvmTerraformTransform` becomes:

1. Ecosystem guard (terraform-only).
2. `Resolve-AvmTool -Name 'mapotf' -AllowPathFallback:$AllowPathFallback`.
3. `Read-AvmAssetConfig -Path $Context.Root`; look up asset descriptor `avm-mapotf-configs-pre-commit`.
4. `Resolve-AvmPinnedAsset -Name 'avm-mapotf-configs-pre-commit' -Asset <descriptor>` → on-disk dir with the 3 configs.
5. `Invoke-AvmProcess` mapotf with argv `transform --mptf-dir <pinned> --tf-dir .` from `$Context.Root`.
6. `Invoke-AvmProcess` mapotf with argv `clean-backup --tf-dir .` from `$Context.Root` (removes the `.bak` files mapotf leaves).
7. Standard `pscustomobject` envelope (`Engine='terraform'`, `Tool='mapotf/<ver>'`, `Status='pass'|'fail'`, `Issues=...`).
8. Missing pinned asset or missing tool → `AvmConfigurationException` → chain `skipped`.

### Open follow-ups before Slice G can land

1. **Confirm `mapotf` release-shipping status.** The 2026-05-27 conftest-lock audit (commit `d2ab4e2`, see Phase 2 §2 row in `docs/progress.md`) noted mapotf does not ship releases today. Owner: investigate `lonegunmanb/mapotf` (canonical home; `Azure/mapotf` is a hard fork not actively releasing). If still absent → resolve next item.
2. **Pick a hosting strategy for mapotf release artefacts.** Three options: (i) PR a release workflow into upstream `lonegunmanb/mapotf`; (ii) build + host artefacts in `Azure/avm-terraform-governance` releases; (iii) build + host in this repo's own releases. **User decision** — same A/B/C question already open from the 2026-05-27 audit.
3. **Confirm config pinning approach.** Pinned-asset bundle ships as (i) tarball of upstream `mapotf-configs/pre-commit/` at a specific SHA, or (ii) re-bundled tagged release on our side. (i) keeps drift visible to consumers; (ii) gives us editorial control. **User decision; default = (i).**
4. **Settle the pinned-asset descriptor name.** Proposed: `avm-mapotf-configs-pre-commit`. Aligns with `avm-policy-aprl` / `avm-policy-avmsec` already in use.

### What is deliberately deferred

- **Reimplementation in PowerShell or `hcledit` if `mapotf` proves unhostable.** If follow-ups #1 + #2 conclude that build-and-host is more expensive than expected, fall back to **(b) `hcledit`** in preference to **(a) PowerShell** — it ships releases, has a stable CLI surface, and the dependency-graph cost is bounded. Track as a new audit slice if it triggers.
- **Replacing `mapotf clean-backup` with a `Remove-Item *.bak -Recurse`.** Trivial substitution, but only worth it if we're already off mapotf. Same dependency as the above.

## Appendix C. Decision: avmfix replacement strategy

> **UPDATE 2026-06-19 — `avmfix` is DEPRECATED upstream and replaced by `mapotf`. This appendix is now a historical behaviour catalogue, not a live decision.** Per user direction (2026-06-19) and confirmed against the upstream repos: `lonegunmanb/avmfix` is deprecated; AVM Terraform governance now performs **all** of avmfix's reordering/hygiene work via `mapotf transform` with the nine hosted `mapotf-configs/pre-commit/*.mptf.hcl` configs (see [Appendix B](#appendix-b-decision-mapotf-replacement-strategy) update + [Appendix J](#appendix-j-2026-06-19-terraform-pre-commit-ground-truth-refresh)). The mapping from this 10-behaviour catalogue to the mapotf configs:
> - **#1 resource/data/ephemeral block ordering** → `order_resource_attrs` + `order_resource_meta` (`reorder_attributes` primitive).
> - **#2 module block ordering** → `order_module_attrs`.
> - **#3 azapi overrides** → `avm_headers_for_azapi`.
> - **#4 variable attr ordering + hygiene** → `sort_variables` (`reorder_attributes` + `remove_block_element` dropping `nullable=true`/`sensitive=false`/`ephemeral=false`).
> - **#5 variables-file partitioning + relocation** → `move_misplaced_blocks` (moves non-canonical blocks to `main.tf`) + `sort_variables` (`sort_blocks_in_file`, required-alpha then optional-alpha, per-file `for_each` so multi-file `variables.*.tf` layouts survive).
> - **#6 output attr ordering + hygiene** → `sort_outputs`.
> - **#7 outputs-file partitioning + relocation** → `move_misplaced_blocks` + `sort_outputs`.
> - **#8 locals / #9 moved-removed / #10 terraform-block ordering** → covered by the `order_*` configs + mapotf's writer.
>
> **Consequence:** Slice H stays closed (no avmfix chain). The "build-and-host avmfix" recommendation below is **superseded** — avmfix is not adopted in any form; its behaviours come from wrapping mapotf (Slice G). The catalogue is preserved because it is the precise map of *what the mapotf configs now do*, which is invaluable when validating a Slice G run.

**Context.** Upstream `avm-terraform-governance@65182443` runs `avmfix --folder . --exclude <pattern>` against the module root, then again against each subdir of `./modules` and `./examples` at `depth=1`. avmfix (`lonegunmanb/avmfix@a8d494fe`, ~3 KB main + ~37 files under `pkg/`) is structured as a per-file walker that runs **twice** in succession (file-relocation passes can move blocks between `variables.tf` / `outputs.tf` / `main.tf`, which then need re-walking) over every `*.tf` file in scope. This audit answers, per behaviour: (1) what does it concretely do; (2) is it important to the AVM contract; (3) is it covered by `terraform fmt`; (4) what is the cheapest replacement (drop / general CLI / native PowerShell / keep upstream via build-and-host); (5) effort. Read it before Slice H (`Format-AvmTerraformModule` avmfix-equivalent chain).

### Per-behaviour audit

| # | Behaviour | Schema-dependent? | Important? | `terraform fmt` covers? | Cheapest replacement |
|---|-----------|--------------------|------------|--------------------------|----------------------|
| 1 | **Resource / data / ephemeral block ordering** — head-meta (`for_each` / `count` / `provider`) first; then required args (alpha-sorted); then optional args (alpha-sorted); then required nested blocks (alpha); then optional nested blocks (alpha); then tail-meta (`lifecycle` / `depends_on`). Required-vs-optional classification reads the provider plugin's V5 or V6 schema response, fetched by downloading the provider binary from `registry.opentofu.org` and running it as a gRPC subprocess (HashiCorp `go-plugin` framework). Cached per-(namespace, name, version). | **Yes — heavy**. Needs real provider plugin binary + gRPC. | **Yes**. AVM Bicep+TF Codex §TFNFR23 / §TFNFR24 mandates this exact ordering for module-author readability + diff stability. | No — `terraform fmt` is whitespace + alignment only; never reorders. | **(c) Keep avmfix via build-and-host.** Alternatives all break: `hcledit` / `topiary` can't read provider schemas; native PowerShell would need to re-implement Terraform's plugin gRPC protocol. The escape hatch is **(d) shell to `terraform providers schema -json`** (already requires `terraform init`, which avmfix runs anyway) + a PowerShell HCL surface-tree rewriter — viable but ~6× the code of orchestrating the upstream binary. |
| 2 | **Module block ordering** — head-meta (`for_each` / `count` / `source` / `version` / `providers`), then required module vars (alpha), then optional module vars (alpha), then `depends_on`. Required-vs-optional classification reads the local module via `hashicorp/terraform-config-inspect` (lighter than gRPC — it just parses the target module's `variables.tf`). | **Yes — light**. `tfconfig.LoadModule` only. | **Yes**. Same codex clause as #1, applied to consumer-side `module` blocks. | No. | **(c)**. Could also be **(a) PowerShell** if isolated, since `terraform-config-inspect` is replaceable with a `Read-AvmHclSurface` walker over `variables.tf` files. Bundles for free under (c). |
| 3 | **azapi schema post-processor** — promotes `name` / `parent_id` / `location` / `resource_id` / `action` / `method` / `query_parameters` to required for `azapi_resource` / `azapi_update_resource` / `azapi_resource_action`, overriding the upstream provider schema (which marks them optional). | **Yes** — overlays on #1's schema fetch. | **Yes**. Without it, the most important `azapi_resource` arguments get sorted into the optional alpha bucket — confusing in long-form modules. | No. | **(c)**. Trivial to keep in PowerShell if we ever own #1, but pointless to split. |
| 4 | **Variable block attribute ordering + hygiene** — orders attrs `type` / `default` / `description` / `nullable` / `sensitive`; removes `nullable = true` (the default); removes `sensitive = false` (the default). | No. | **Yes**. Codex mandate; removing the defaults keeps `terraform fmt`-clean output and matches generated `Set-AVMModule` baseline. | No — fmt doesn't reorder attributes or strip default-valued ones. | **(a) PowerShell** trivially. Bundles with (c) for free. |
| 5 | **Variable file block ordering + relocation** — within `variables.tf`: required `variable` blocks (no `default`) first alpha, then optional alpha; any non-`variable` block in `variables.tf` is moved to `main.tf` (creates `main.tf` if needed). | No. | **Yes**. Codex tenet; otherwise `variables.tf` becomes a kitchen sink. | No. | **(a) PowerShell** straightforward (file partitioning + alpha sort by label). Bundles with (c) for free. |
| 6 | **Output block ordering + hygiene** — alpha-sort attrs; removes `sensitive = false`. | No. | **Yes**. Mirror of #4 for outputs. | No. | **(a)**. Bundles with (c). |
| 7 | **Output file ordering + relocation** — within `outputs.tf`: alpha-sort `output` blocks by label; move non-`output` blocks to `main.tf`. | No. | **Yes**. Mirror of #5. | No. | **(a)**. Bundles with (c). |
| 8 | **Locals block ordering** — alpha-sort local attributes within each `locals { }` block. | No. | **Yes**, lower bar (cosmetic; matters for diff stability but no runtime impact). | No. | **(a)** one-liner. Bundles with (c). |
| 9 | **`moved` / `removed` block ordering** — `moved` blocks: `from` then `to`; `removed` blocks: `from` attr, then `lifecycle` nested block, then `provisioner` nested blocks in order. | No. | **Yes**, low bar — Terraform doesn't care about attribute order in these refactor blocks; the rule exists for human readability of state-migration commits. | No. | **(a)** trivial. Bundles with (c). |
| 10 | **`terraform` block ordering** — top-level: `required_version` first (then `experiments` if present); then `backend` / `cloud` / `provider_meta` nested blocks; then `required_providers` last. Inside `required_providers`: alpha-sort by provider name. | No. | **Yes**. Codex clause; canonical layout for module heads. | No. | **(a)** trivial. Bundles with (c). |

**Orchestration dependencies that come with avmfix:**

- `terraform init -backend=false` runs first (downloads providers + modules, writes `.terraform.lock.hcl`). Behaviours #1–#3 won't fire correctly without it.
- HTTPS calls to `registry.terraform.io` (provider version lookup when `.terraform.lock.hcl` omits a version) and `registry.opentofu.org` (provider plugin binary download).
- gRPC subprocess per (namespace, name, version) tuple, holding the provider plugin open for schema queries. Cached in-process; cleaned up at end.
- Two-pass `AutoFix` (file-relocation requires re-walk).
- `--exclude <glob>` for skip-file filtering.

### Recommended option: **(c) keep avmfix via build-and-host** (mirror of mapotf decision)

Concrete reasoning:

1. **Behaviours #1–#3 require provider schemas.** No general CLI (`hcledit`, `topiary`) reads them. A PowerShell port would need to either re-implement Terraform's plugin gRPC protocol (impractical — HashiCorp `go-plugin` framework with mTLS handshake), or shell out to `terraform providers schema -json` (viable — see option (d) below). Both paths are several times more code than packaging the existing Go binary.
2. **`terraform fmt` covers zero of avmfix's 10 behaviours.** It only normalises whitespace, indentation, brace placement, and alignment. avmfix is purely semantic re-ordering + default-attribute pruning. No double-fixing risk; the two are complementary.
3. **Behaviours #4–#10 (the schema-free 7) are individually trivial.** They're alpha-sorts and literal-attribute deletions. They could be ported to PowerShell in a few hundred lines. But that doesn't motivate splitting the tool — once we depend on the binary for #1–#3, the schema-free behaviours come for free.
4. **avmfix the tool is small.** ~37 files under `pkg/` plus a 50-line `main.go`. ~21 KB of `schema_map.go` is the largest single file (the in-memory schema cache). Hosting a release for it costs the same as for mapotf — they're the same shape of decision.
5. **Both mapotf + avmfix block on the same supply-chain question.** The four open follow-ups from Slice E (mapotf) extend to avmfix verbatim. Resolving them once unblocks both Slice G and Slice H.

### Slice H implementation outline (if option (c) holds)

`Format-AvmTerraformModule` becomes:

1. Ecosystem guard (terraform-only).
2. `terraform fmt -recursive .` (existing — no change).
3. `Resolve-AvmTool -Name 'avmfix' -AllowPathFallback:$AllowPathFallback`. Missing tool → `AvmConfigurationException` → chain `skipped`.
4. `Resolve-AvmTool -Name 'terraform'` — required for avmfix's `terraform init -backend=false`. If absent: same skip path.
5. `Invoke-AvmProcess` avmfix with argv `--folder . --exclude <pattern-from-config-if-any>` from `$Context.Root` (matches upstream porch step 8 first invocation).
6. For each subdir of `<Root>/modules` at `depth=1`: same argv with `--folder modules/<name>`.
7. For each subdir of `<Root>/examples` at `depth=1`: same argv with `--folder examples/<name>`.
8. Aggregate `Issues` from any non-zero exits into the standard `pscustomobject` envelope (`Engine='terraform'`, `Tool='avmfix/<ver>'`, `Status='pass'|'fail'`, `Issues=...`). avmfix has no JSON output mode — `Issues` parses stderr line-for-line.
9. `Changed` count = sum of files-modified across the 3 invocations; surface alongside `Status` so the chain knows whether the format step actually mutated anything.

### Open follow-ups before Slice H can land

1. **Confirm `avmfix` release-shipping status.** The 2026-05-27 conftest-lock audit (commit `d2ab4e2`, see Phase 2 §2 row in `docs/progress.md`) noted avmfix does not ship releases today. Owner: investigate `lonegunmanb/avmfix` (canonical home; no `Azure/avmfix` fork exists, unlike mapotf). If still absent → resolve next item.
2. **Pick a hosting strategy for avmfix release artefacts.** Same A/B/C as mapotf: (i) PR a release workflow into upstream `lonegunmanb/avmfix`; (ii) build + host artefacts in `Azure/avm-terraform-governance` releases; (iii) build + host in this repo's own releases. **User decision** — resolve once for both mapotf + avmfix.
3. **Settle the `tools.lock.psd1` entry shape.** Same shape as `conftest` / `terraform-docs` (binary archive per platform, SHA256-verified). Six platforms: windows/linux/darwin × amd64/arm64. avmfix uses `go-releaser`-style naming if a release workflow is added.
4. **Decide whether to bundle behaviour #2's `terraform-config-inspect` dependency separately.** avmfix vendors it; if we ever rip the schema-free behaviours into PowerShell as an offline fallback, we'd need an equivalent. Defer until follow-up #2 lands.

### What is deliberately deferred

- **Reimplementation in PowerShell via `terraform providers schema -json`.** Option (d) — shell out to `terraform providers schema -json` (already requires `terraform init`, which avmfix runs anyway) for the schema knowledge needed by behaviours #1–#3, plus pure PowerShell for behaviours #4–#10. Avoids the gRPC re-implementation entirely. Viable as a future replacement if (c) becomes too costly to host. Track as a new audit slice if triggered.
- **Splitting #4–#10 into a "fmt+" PowerShell helper that runs even when avmfix is absent.** Possible UX win for offline contributors who can live without the schema-aware bits. Defer until we have evidence that #1–#3 unavailability is actually painful.
- **Replacing avmfix's two-pass loop with our own file-walk.** Trivial substitution, but only worth it if we're already off avmfix. Same dependency as above.
- **A `Test-AvmTerraformFormat` (check-only, no fixes) mode.** avmfix has no `--check` flag; we'd need a separate `--dry-run` patch to upstream or a diff-based wrapper. Track as a Phase 3 deliverable if `pr-check` ends up wanting a non-mutating format gate.

## Appendix E. Decision: credential storage on disk

### Context

Spec §23 OQ 1 (line 667) verbatim:

> **Credential storage.** Use `Microsoft.PowerShell.SecretManagement` (well-supported, cross-platform via SecretStore vault) or a simple file-based store under `<Config>/secrets/` with OS-keychain integration later? Lean: SecretManagement when we first need it (probably Phase 3).

Spec §17 (Secrets) already locks in the in-memory contract for any secret the module touches: **`[SecureString]` parameters only, no plain-text persistence anywhere** (line 547), with three blanket prohibitions (line 546): no secret in source, in default config, in test fixtures, in error messages, or in telemetry. This appendix scopes the *persistence* question that §17 leaves open.

### Today's reality (what the module actually persists)

Grep of `src/Avm.Authoring/` for `secret|credential|token|password|api[_-]?key` (case-insensitive) returns **zero hits** outside of CLI argv parsing tokens and one doc comment about `terraform test` not needing real backend credentials. **The module persists no secrets at all today.** Every wired engine is offline-friendly: `format`, `lint`, `test`, `docs`, `check policy` (against pinned-asset bundles, no remote OPA), and the `transform` / `check convention` stubs all run without auth.

The only secret the codebase touches in any form is the PowerShell Gallery API key consumed by `scripts/Publish-AvmAuthoring.ps1`, and that script has been engineered (per spec §17 line 549) to accept the key from the caller's environment + run inside a protected GitHub Environment with required reviewers, so even in CI nothing lands on disk.

### Spec deviation surfaced by this audit

`scripts/Publish-AvmAuthoring.ps1` line 4 declares `[string] $ApiKey`. Spec §17 line 548 mandates `[SecureString]` only ("The publish script (`scripts/Publish-AvmAuthoring.ps1`) accepts the API key as `[SecureString]` only"). Same shape as the §6-line-220 finding that Appendix D surfaced and Slice K closed: a 4-line parameter-type swap + an `ConvertFrom-SecureString -AsPlainText` at the `Publish-PSResource -ApiKey ...` call site (line 86) to satisfy PSResourceGet's plain-`[string]` `-ApiKey` parameter at the boundary. Tracked as **Slice M** (follow-up to this audit, not part of the audit deliverable).

### Plausible future secrets we might need to persist

| Hypothetical need                            | When                          | Persistence required?                                      |
| -------------------------------------------- | ----------------------------- | ---------------------------------------------------------- |
| Telemetry endpoint API key                   | Phase 3 §21 if posts auth     | **Likely** — telemetry must be unattended on every CLI run |
| Bicep ACR pull/push credentials              | Bicep CLI revival (defocused) | Maybe — ACR usually MSAL/ManagedIdentity, not persisted    |
| `AVM_MIRROR` host with auth                  | Never (spec §16 HTTPS-only)   | No — URLs would be the wrong shape                         |
| Conftest OPA bundle pull from private remote | Never (pinned-asset SHA)      | No                                                         |
| Git mirror auth (e.g. Azure DevOps PAT)      | Never (we never clone in CLI) | No                                                         |
| PSGallery API key                            | Never (publish runs in CI)    | No                                                         |

**One realistic trigger only: Phase 3 telemetry posting to an authenticated endpoint.** And even that one is conditional — anonymous telemetry endpoints exist, so the trigger only fires if the endpoint design picks an auth model. That decision lives in the open Telemetry design note (spec §21 / §23 OQ 4 / progress.md cross-phase backlog) — not in this audit.

### Options

(a) **`Microsoft.PowerShell.SecretManagement` + `Microsoft.PowerShell.SecretStore`** vault. Cross-platform PSGallery modules, official Microsoft-maintained, ~1.1+ stable. SecretStore backend uses platform-native crypto (DPAPI on Windows, AES-GCM with master password on Linux/macOS). Bootstrap UX is a one-liner: `Set-Secret -Name <n> -SecureStringSecret (Read-Host -AsSecureString)`. CI runs unlock the vault with `-Authentication None -Interaction None` against an env-sourced master password.

(b) **File-based store under `<Config>/secrets/<name>.json`** with OS-keychain integration deferred. POSIX 0o600 on Linux/macOS; Windows DPAPI-wrapped via `ConvertFrom-SecureString` (which is DPAPI on Windows, AES-GCM derived from a key file on Linux/macOS). Requires us to ship `Get-AvmCredential` / `Set-AvmCredential` / `Remove-AvmCredential` helpers and own the schema, the encryption story, the rotation story, the secure-delete story, and the test surface.

(c) **Never persist secrets in the module.** Keep the current "SecureString-in-memory + caller's responsibility to source from elsewhere (env var, prompt, CI secret)" stance. Means every authenticated operation requires the caller to provide the secret at every invocation, either interactively (`Read-Host -AsSecureString`) or via an env-var-to-SecureString conversion at the dispatcher boundary.

### Per-option cost/benefit

| Axis                            | (a) SecretManagement              | (b) File-based                  | (c) Never persist          |
| ------------------------------- | --------------------------------- | ------------------------------- | -------------------------- |
| Cross-platform                  | ✅ Native                          | ⚠️ Need to write the porting layer | ✅ N/A                      |
| OS keychain hand-off            | ✅ Pluggable backends              | ❌ "Later" (deferred indefinitely)  | ✅ N/A                      |
| Spec §17 line 547 conformance   | ✅ Native (`Get-Secret` is `[SecureString]`) | ⚠️ Must wrap `ConvertFrom-SecureString` correctly | ✅ Trivially  |
| Module surface to maintain      | ~30 lines (`Get-AvmCredential` wrapper) | ~300 lines + crypto + tests | 0 lines                    |
| CI bootstrap                    | One env var (`SECRETSTORE_PASSWORD`) | One env var per secret           | One env var per secret     |
| Module-load cost                | Lazy import of vault module       | Negligible                      | Zero                       |
| Audit posture                   | Microsoft-maintained, ~5+ years old | Ours; needs threat model + reviews  | N/A                        |
| Day-1 implementation effort     | ~half a day when needed           | ~3–5 days when needed           | Zero                       |

### Recommended option: **(c) Never persist secrets — until Phase 3 telemetry forces our hand, then (a)**

Rationale:

- Spec lean already says "SecretManagement when we first need it (probably Phase 3)" — this audit confirms the timing: today the module has *no* persisted secrets, and the only plausible trigger is Phase 3 telemetry (and even that's conditional on the endpoint design).
- (b) loses to (a) on every axis except day-1 dependency footprint, and the dependency footprint argument is weak because `Microsoft.PowerShell.SecretManagement` is a standard Microsoft module already heavily used in PowerShell tooling (cf. Az.Accounts, Microsoft.Graph). It's not exotic.
- (c) is the cheapest correct option today and keeps the module's surface minimal until we have a real consumer to design against.
- When Phase 3 telemetry lands, picking (a) over (b) is a 30-line `Get-AvmCredential` wrapper around `Get-Secret` plus one-time bootstrap UX, not a 300-line file-store + crypto + threat-model exercise.

### Slice implementation outline (deferred — fires when Phase 3 telemetry endpoint design picks an authenticated model)

1. Add to `Avm.Authoring.psd1` `RequiredModules`:
   ```pwsh
   RequiredModules = @(
       @{ ModuleName = 'Microsoft.PowerShell.SecretManagement'; ModuleVersion = '1.1.2' }
       @{ ModuleName = 'Microsoft.PowerShell.SecretStore';      ModuleVersion = '1.0.6' }
   )
   ```
2. New private helper `src/Avm.Authoring/Private/Credentials/Get-AvmCredential.ps1` — thin wrapper over `Get-Secret` that scopes to a vault named `Avm.Authoring`, registers the vault lazily on first use, and returns `[SecureString]`.
3. New public verb `avm credential set <name>` (handler `Public/Set-AvmCredential.ps1`) that prompts via `Read-Host -AsSecureString` and stores via `Set-Secret`.
4. New public verb `avm credential remove <name>` (handler `Public/Remove-AvmCredential.ps1`) that wraps `Remove-Secret`.
5. CI bootstrap: telemetry-posting tests set the SecretStore master password from `${{ secrets.AVM_SECRETSTORE_PASSWORD }}` via `Set-SecretStoreConfiguration -Authentication None -Interaction None` + `Unlock-SecretStore` — same pattern other Microsoft modules use in their integration suites.
6. Threat-model gate at PR review per spec §1 ("every credential touch is threat-modelled at PR time"): document the secret's lifetime, blast radius, rotation procedure, and revocation steps in the PR description.
7. Test coverage: unit tests use the `Microsoft.PowerShell.SecretStore` in-memory mode; CI tests use a fresh-per-job vault.

### Open follow-ups

- **Slice M** — convert `scripts/Publish-AvmAuthoring.ps1 $ApiKey` parameter from `[string]` to `[SecureString]` per spec §17 line 548. Mirror of Slice K's pattern: small surface, regression test the parameter type, document the in-memory `ConvertFrom-SecureString -AsPlainText` at the `Publish-PSResource` boundary (the gallery API requires plain-`[string]`). **Autopilot-safe — tracked separately from this audit.**
- When telemetry endpoint design lands, confirm whether the endpoint needs auth at all. If anonymous, this audit's recommendation stays (c) indefinitely.
- When Bicep ACR support is unblocked (defocused per 2026-05-26), audit whether MSAL/ManagedIdentity flows cover the auth without needing a persisted secret.

### Deliberately deferred

- Building a custom AVM-specific vault backend (option (a)'s pluggability is good enough).
- Building the `avm credential` UX before there's a consumer that needs it.
- File-based store (option (b)) — re-litigate only if (a) is found to have a hard portability or telemetry-CI blocker that this audit's table missed.

## Appendix F. Decision: `dotnet tool` packaging as a Phase 0 distribution channel

### Context

Spec §23 OQ 5 (line 671) verbatim:

> **`dotnet tool` packaging.** Adopt as a Phase 0 distribution channel for future-proofing, or wait for Phase 3 Hybrid mode? Lean: wait — packaging effort isn't justified until Hybrid is real.

Consolidation plan §11 OQ 4 (line 495) re-asks the same question, and the plan's distribution-channel table (lines 460–462) marks `dotnet tool` as **Phase 3+, "Only if Option 3 (Hybrid) is activated"**. This appendix grounds that lean against the module's actual shape and writes the trigger conditions down so a future session doesn't re-litigate it.

### What `dotnet tool` actually distributes

`dotnet tool install -g <id>` consumes a NuGet package built with `<PackAsTool>true</PackAsTool>` (and either `<PackageType>DotnetTool</PackageType>` for global tools or `DotnetCliTool` for tool-manifest local tools). The .NET CLI shells out to a generated wrapper that invokes `dotnet <tool.dll>`. **The package's payload is .NET IL** — managed assemblies, a `.runtimeconfig.json`, and a `tools/<tfm>/any/<id>.dll`. The runtime is the user's installed .NET SDK or runtime; the tool itself is not a single self-contained binary.

There is **no first-class story for packaging a pure-PowerShell module as a `dotnet tool`**. The two community attempts I'm aware of (`PowerShell.DotnetTool.SDK` patterns; one-off projects on GitHub) all wrap a PowerShell host inside a .NET console app that fires up a runspace, imports the embedded module, and dispatches. That's a non-trivial host shim — it's exactly the Hybrid-mode (Option 3) architecture from `docs/avm-consolidation-plan.md` §3, just with a different distribution wrapper around it.

Stated baldly: **`dotnet tool` packaging is the *distribution channel* for the Hybrid (Option 3) shape**. It is not a *separate* decision; it is downstream of the Hybrid-versus-not decision.

### Today's distribution reality

| Channel                | Status                  | Driver                                                                                  |
| ---------------------- | ----------------------- | --------------------------------------------------------------------------------------- |
| **PSGallery**          | ✅ Wired (Slice M closes the publish-script gap; release workflow drives it) | The canonical PowerShell module distribution channel; first-class `Install-Module` / `Install-PSResource` UX |
| **GitHub Releases (.nupkg)** | 🟡 Implicit (the publish workflow uploads to PSGallery, which is itself .nupkg-based; no separate GH Releases artifact) | Already on the Phase 6 list for parity with the legacy `./avm` shim users |
| **`dotnet tool`**      | ❌ Not started, not on Phase 0–2 list | Would require the Hybrid host shim — out of scope until Option 3 fires |
| **Homebrew tap, Scoop bucket** | ❌ Phase 3+ ("Hybrid path only" per plan line 462) | Same dependency: needs a single-binary artifact, which Hybrid produces |

### What we'd actually need to do to ship `dotnet tool` today

To package the current PowerShell module as a `dotnet tool` we would have to:

1. **Build a .NET host shim** — a small C# console project that boots a `PowerShell` runspace (via `Microsoft.PowerShell.SDK` NuGet package), imports the embedded `Avm.Authoring` module, parses argv, and dispatches to `Invoke-Avm`. This is ~200–500 LOC of C# plus a `.csproj` plus a build target that embeds the `src/Avm.Authoring/**` content as a NuGet content folder.
2. **Decide the runtime story** — `Microsoft.PowerShell.SDK` pulls in **the entire PowerShell 7 runtime** as a dependency (~80 MB unpacked). A `dotnet tool` package shipping the SDK is fat (~50–100 MB compressed) vs. the current `Avm.Authoring.psd1` PSGallery payload (~250 KB). The alternative is documenting `pwsh 7.4+` as a prerequisite and shelling out to it, which is uglier UX than just installing the PSGallery module directly.
3. **Cross-publish per RID** — `dotnet tool` packages are technically platform-agnostic by default (`tfm=net8.0`, `runtime=any`), but if we embed any platform-specific helper (e.g., the cancellation-on-Windows code from spec §23 OQ 3 once it lands) we'd have to ship per-RID variants. That's a separate complication that PSGallery doesn't have.
4. **Mirror every release to NuGet.org** — `dotnet tool install -g <id>` resolves from NuGet.org by default. We'd need a NuGet.org account in the `Azure` org, an API key, a publish step in `.github/workflows/release.yml`, and signed packages (NuGet.org requires `--api-key` + recommends Authenticode-signed NuGet packages for verified-publisher status).
5. **Write per-channel install docs** — README would need separate sections for "Install via PSGallery" (already there), "Install via `dotnet tool`" (new), and the divergence in command surface (none — both should invoke the same `avm` verbs).

### Per-trigger evaluation

| Trigger that might justify `dotnet tool` today | Fires?                            | Why                                                                                                     |
| ---------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Users without PowerShell installed              | ❌                                 | The CLI *is* a PowerShell module; `pwsh 7.4+` is already a hard prerequisite per spec §2. A `dotnet tool` wrapper still requires either the SDK runtime bundled (fat) or `pwsh` on PATH (same prereq). No net UX win. |
| Users with `dotnet` already installed, no `pwsh` | ⚠️ Hypothetical                    | Plausible cohort: a developer of a .NET-only repo who's never touched PowerShell. But they still need `pwsh` for the engine to run; the `dotnet tool` wrapper just hides one install step. Net win is one fewer documented prerequisite, not a different runtime. |
| CI environments where `Install-Module` is awkward | ❌                                 | GitHub Actions, Azure DevOps, GitLab CI all have first-class `Install-Module` / `Install-PSResource` support. No CI environment in 2026 lacks PSGallery access if it has `dotnet`. |
| Future Hybrid binary distribution               | ✅ but Phase 3                     | This is exactly what the spec lean says — when Option 3 fires, `dotnet tool` joins the channel mix. The work shape changes from "package a PS module as a fat .NET tool" (today: silly) to "package a real .NET binary as a thin .NET tool" (Phase 3: natural). |
| Avoiding PSGallery dependency                   | ❌                                 | PSGallery is the canonical PowerShell module channel; avoiding it is anti-PowerShell-ecosystem. The plan keeps the PowerShell module on PSGallery even after Hybrid (plan line 84: "GitHub Releases (single binary), `dotnet tool`, plus a PSGallery module for direct PS use"). |

**Zero of the triggers fire today.** The Hybrid trigger is the only one that does, and it's by definition Phase 3+.

### Recommended option: **defer to Phase 3 (matches spec lean — no change)**

Confirm the spec §23 OQ 5 lean and the plan §11 OQ 4 lean. Track no new work. Update the spec/plan only if a Phase 3 trigger surfaces.

Specifically: do **not**
- Add `<PackAsTool>` plumbing to a `.csproj` we don't have.
- Build a `Microsoft.PowerShell.SDK`-based host shim.
- Create a NuGet.org account in the `Azure` org or wire a publish step.
- Document `dotnet tool install -g Avm.Authoring` anywhere (it would mislead users — it doesn't work and won't work until Phase 3).

### Trigger conditions that would re-open this audit

Any of the following would justify revisiting:

1. **Option 3 (Hybrid) is formally activated.** Plan §3 lists this as Phase 3+; the trigger is "(a) the verb surface is stable and (b) a polished single-binary UX has measurable value over the PS module" (plan line 96). When activated, `dotnet tool` joins Homebrew + Scoop as one of three first-class distribution channels for the Hybrid binary.
2. **A user-research signal that `pwsh 7.4+` prerequisite is itself the install blocker.** Today there's zero evidence of this — every AVM contributor already has `pwsh` for the legacy `./avm.ps1` shim. If post-Phase 6 telemetry (if it exists by then) shows a meaningful "tried to install, didn't have pwsh, gave up" cohort, the calculation changes.
3. **Microsoft publishes a `Microsoft.PowerShell.GlobalTool` SDK** that packages a `pwsh` module as a `dotnet tool` with first-class support (i.e., no hand-written host shim). The 2024–2026 .NET 8/9/10 tool work hasn't shipped this; if it does, the cost of (1) and (2) above drops materially.

### Deliberately deferred (do not pre-build)

- Authoring a `.csproj` for a `Microsoft.PowerShell.SDK` host shim. Wait for Hybrid.
- Reserving the `Avm.Authoring` NuGet.org package ID. Only useful if we actually publish; reserving without publishing creates user confusion about which channel is real.
- Adding `dotnet tool install` instructions to README. Same reasoning — would mislead users.
- Building a `.github/workflows/release-dotnet-tool.yml`. Phase 3 deliverable.

### Open follow-ups

- **Telemetry design note** is answered by [Appendix G](#appendix-g-decision-telemetry-design). A Phase 3 telemetry implementation lets us observe the "pwsh prerequisite as install blocker" re-open trigger above; without it, the trigger is permanently unobservable.
- When Phase 3 starts and Option 3 is activated, **this appendix should be promoted to a Phase 3 spec section** (or a sibling appendix `Appendix F-1`) covering the actual distribution-channel cut-over plan, not a defer-or-not decision.

---

## Appendix G. Decision: telemetry design

> **Status (Slice O, 2026-06-06): design locked, implementation deferred to Phase 3 per spec §21.** This appendix resolves plan §11 OQ 5 ("should the CLI emit anonymised usage telemetry to help the AVM team understand adoption, and if so what's the opt-out story?") and fills in the "TBD in the Phase 3 design note" gaps that spec §21 explicitly leaves open (endpoint, storage of install-id, opt-in UX precedence, threat model, failure handling). Nothing in this appendix changes the privacy contract spec §21 already locked. It only adds the engineering detail needed for a future Phase 3 slice to ship an implementation without re-deriving any of these decisions.

### Context

Spec §21 ([`avm-implementation-spec.md`](avm-implementation-spec.md#21-telemetry-deferred-to-phase-3)) locks the **privacy contract** for telemetry:

- **Default**: off.
- **Opt-in**: `$env:AVM_TELEMETRY = 'on'` or `Set-AvmConfig -Telemetry On`.
- **Payload**: verb name, exit code, duration in ms, OS, architecture, CLI version, anonymised install ID (UUID v4 generated once and stored in `<Config>/install-id`).
- **Never sent**: repo paths, module names, env vars, error messages, user identity, file contents, hostnames.
- **Endpoint and storage**: TBD in the Phase 3 design note.

Plan §11 OQ 5 mirrors the question. The user has not yet signalled either way on whether telemetry should ship at all.

This appendix answers the eight questions a Phase 3 implementer would otherwise have to re-litigate from scratch. It is intentionally implementation-shaped (concrete payloads, file paths, env-var names, fallback rules) — not a re-statement of the spec's privacy paragraph.

### Today's reality

- **Zero telemetry code in the tree.** A repo-wide grep for `AVM_TELEMETRY` / `Set-AvmConfig` / `install-id` / `telemetry` returns no `src/` hits. Spec §21 is a forward-looking contract; nothing is wired.
- **Zero telemetry endpoint commitment from the AVM team.** No App Insights instrumentation key, no Azure Function URL, no Application Insights resource exists in the Azure subscription used by this repo.
- **One existing telemetry channel in the AVM contract — but it is *not* this one.** The Terraform AVM module contract requires `main.telemetry.tf` (locals + `data.azapi_client_config.telemetry` + `data.modtm_module_source.telemetry` + `resource.random_uuid.telemetry` + `resource.modtm_telemetry.telemetry`). The `modtm` resource emits a telemetry beacon when `terraform apply` runs against an AVM module. This is **module-deployment telemetry** — it tells the AVM team "module X was deployed once today." It is owned by the AVM Terraform module contract, materialised by the `main_telemetry_tf.mptf.hcl` config that `mapotf transform` writes into the module under test, and emitted by `terraform apply` running against an instrumented module. It is **not** owned by `Avm.Authoring`, and `Avm.Authoring` neither emits it nor reads it. See "Question 7" below for the strict separation rule.

### Question 1 — should we have CLI-level telemetry at all?

**Recommendation: yes, but only as defined by spec §21 (opt-in, anonymous, narrow payload).** Three reasons:

1. **Adoption signal we can't get any other way.** Spec §21 lists the payload as: verb name, exit code, duration, OS, architecture, CLI version, anonymised install ID. That gives the AVM team a coarse-grained read on (a) is anyone using `avm pre-commit` at all, (b) what's the OS/version distribution, (c) what verbs are most-used (so we know where to invest), (d) what verbs fail (so we know what to fix), (e) what verbs are slow (so we know what to optimise). All five questions are unobservable from PSGallery download counts alone, which only tell us "module was downloaded" — not "module was invoked".
2. **PSGallery download counts are noisy.** CI pipelines mass-install the module on every PR; one user could account for thousands of downloads. Install-ID-deduplicated invocation counts are the only honest measure of *active* users.
3. **Without it, the Phase 3 distribution-channel cut-over (Hybrid, `dotnet tool`, etc.) is decision-by-vibe.** [Appendix F](#appendix-f-decision-dotnet-tool-packaging-as-a-phase-0-distribution-channel) flagged "user-research signal that `pwsh 7.4+` prerequisite is itself the install blocker" as a re-open trigger. Telemetry is how we'd observe that signal: if `osPlatform=Linux` and `psVersion<7.4` show up frequently in *failed* invocations of `pwsh -Command 'Get-Module -Name Avm.Authoring'`, we know. Without telemetry, the Hybrid trigger condition is permanently unobservable.

**Counter-arguments considered and rejected:**

- "Telemetry is hostile to users." This concern is real but does not generalise. Spec §21's contract — *default off, opt-in only, anonymous payload, never sends paths or env vars or hostnames* — is materially different from the kind of always-on, identifying telemetry that has earned the practice a bad name. The opt-in default is the critical part; this is not "you can disable it if you find the toggle." This is "it does nothing unless you explicitly turn it on."
- "Opt-in telemetry will return zero signal because no one opts in." Possibly. Acceptable risk: we ship the channel, document it prominently in CONTRIBUTING.md and README, and ask AVM core team members + power users (the population whose feedback we most need) to opt in. Even N=50 opt-in users gives us better signal than N=0.
- "PSGallery has its own telemetry — that's enough." It is not. PSGallery counts module downloads, not module invocations. A CI matrix that installs the module on 12 OS/architecture combinations per PR registers as 12 downloads per PR — but zero `avm pre-commit` invocations on developer workstations.

### Question 2 — what's the endpoint?

Four candidate endpoints, each with cost / benefit:

| Option                          | What it is                                                                                                                  | Cost                                                                                                       | Benefit                                                                                  | Verdict                                                                                                                              |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **(a) Azure Application Insights** | Microsoft-owned APM service. Anonymous instrumentation-key beacons are a first-class scenario. KQL for analysis.            | Requires Microsoft AVM team to provision a resource + share the instrumentation key (embedded in module). | First-party, free for our volume, mature KQL query story, integrates with Azure Monitor. | **Recommended.** Keeps data inside Microsoft, no third-party processor, no GDPR data-processing addendum required for AVM team use.   |
| (b) Custom Azure Function       | Tiny `Out-of-process` HTTP trigger that writes batched events to a Storage Account / Log Analytics workspace.               | We own the code, the auth model, the cost.                                                                 | Full control over rate limiting, payload validation, retention.                          | Defer. App Insights covers the use case with far less work; revisit only if App Insights rate limits become an issue at high volume. |
| (c) Reuse `modtm` telemetry     | The same endpoint the Terraform AVM `modtm_telemetry` resource emits to.                                                    | Co-mingles CLI-tooling-adoption signal with module-deployment signal. Confuses both data sets.             | Zero new infrastructure.                                                                 | **Rejected.** See Question 7 — CLI and module-deployment are distinct signals and must stay on separate channels.                    |
| (d) OpenTelemetry collector     | Emit OTLP, let the AVM team point it at whatever back-end they like (App Insights, Honeycomb, self-hosted Tempo).           | Adds an OTel SDK dependency (~ heavy in pwsh).                                                             | Vendor-neutral, future-proof if the AVM team's analytics back-end changes.               | Defer to Phase 3+ if the AVM team ever owns multiple back-ends; today they own zero.                                                 |

**Recommendation: (a) Azure Application Insights**, embedded instrumentation key. Use the Application Insights REST ingestion endpoint directly (`https://dc.applicationinsights.azure.com/v2/track`) rather than the .NET SDK — pure HTTP POST, no SDK dependency, transparent to anyone reading the source. The instrumentation key (a UUID, not a secret in the credential-storage sense — it grants only "post events", not "read events") ships in `Avm.Authoring.psd1`'s `PrivateData` block. Endpoint is read-only at startup; cannot be overridden by env var (closes a redirection-attack vector).

This decision blocks on the AVM core team committing to a specific Application Insights resource and providing the instrumentation key. Captured as an open follow-up below.

### Question 3 — how do we generate and store the install-id?

- **Format**: UUID v4 (RFC 4122). 128 bits of randomness, no PII, no machine-correlation.
- **Generation**: first run that *would have sent telemetry* (i.e. after the user has opted in) generates the install-id via `[guid]::NewGuid().ToString()`. If telemetry is never opted-in, the install-id is never generated and the file never created.
- **Storage path**: `<Config>/install-id`, where `<Config>` is the per-user config dir from `Get-AvmFolder -Kind Config` (Windows: `%APPDATA%\Avm`; Linux/macOS: `${XDG_CONFIG_HOME:-$HOME/.config}/avm`).
- **File format**: a single line containing the UUID, LF-terminated, UTF-8 no BOM, mode `0o600` on POSIX (per [Appendix E](#appendix-e-decision-credential-storage-on-disk) credential-style protections — even though it's not strictly a credential).
- **Lifecycle**:
  - Generated once on first opt-in. Never rotated by the CLI.
  - User-deletable. If the user deletes `<Config>/install-id`, the next opt-in run generates a fresh UUID. We treat the file as user-owned state, not module-owned state.
  - Never reset by `Update-Module` / `Uninstall-Module` / version bumps. The whole point is a stable correlation key so the AVM team can deduplicate (one user opening `avm pre-commit` 100× in a day shouldn't look like 100 distinct adopters).
- **What the install-id is *not***: it is **not** a user-identifier. It is a *workstation*-identifier deliberately bounded to a single user account's config dir. A user on three machines registers as three install-ids; a CI runner that recreates its config dir on every job registers as a fresh install-id per job (which is fine — CI invocations are not the population we're measuring).

### Question 4 — what's the opt-in / opt-out UX?

Spec §21 specifies two knobs (env var + `Set-AvmConfig`). A real implementation needs a third (per-repo `.avm/config.json` `telemetry: <bool>` for repos that want to *force-disable* even if the user has opted in globally — e.g. a contractor-owned repo where the contractor has opted in personally but the client's repo policy forbids any outbound network from CI). Precedence rules:

1. **`.avm/.disable` sentinel exists in the repo** → no telemetry, no questions asked. The kill-switch from spec §11 (line 304) is absolute.
2. **`AVM_OFFLINE=1`** → no telemetry. Same envelope as "do not contact any external endpoint."
3. **Per-repo `.avm/config.json` `telemetry: false`** → no telemetry for invocations whose `-Path` (or cwd) resolves under that repo root.
4. **Per-repo `.avm/config.json` `telemetry: true`** → enable telemetry for that repo *even if* (5) says off. (Use case: a repo wants its own CI to phone home; the user/CI environment hasn't globally opted in.)
5. **Per-user `<Config>/avm.config.json` `telemetry: <bool>`** → user's standing preference. Set by `Set-AvmConfig -Telemetry On|Off`.
6. **`$env:AVM_TELEMETRY = 'on' | 'off'`** → env-var override for a single shell session; wins over the per-user file but loses to the per-repo file (the repo's policy is more specific than the user's shell).
7. **Default** if none of the above resolve a value: **off**.

This gives a layered model: repo policy > env-var override > user preference > default. The kill-switches (`.avm/.disable`, `AVM_OFFLINE`) sit above the whole stack.

**`Set-AvmConfig -Telemetry On|Off`** — minimal public cmdlet shape (Phase 3 scope, listed here so the verb is reserved):

```pwsh
Set-AvmConfig -Telemetry On    # writes <Config>/avm.config.json with telemetry: true
Set-AvmConfig -Telemetry Off   # writes telemetry: false (explicit off, distinct from "default off")
Get-AvmConfig | Select-Object Telemetry, TelemetrySource   # shows current value + which precedence layer set it
```

`TelemetrySource` answers "where is this coming from" (so the user can debug *why* telemetry is on/off without grepping the precedence list above): values are `repo-disable-sentinel` | `offline` | `repo-config` | `env-var` | `user-config` | `default-off`.

### Question 5 — threat model

What could go wrong, and how the design defends:

| Threat                                                                                       | Defence                                                                                                                                                                                                                                                                                |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repo paths leak via `verb`/`error` fields                                                    | Payload schema is closed (no free-text fields). `verb` is one of a hardcoded enum (`pre-commit`, `pr-check`, `format`, `lint`, …). No `error`/`message` field exists. Exit code is a number.                                                                                            |
| Hostname leaks via TLS handshake or env                                                     | The HTTP layer uses `Invoke-AvmHttp`, which does not send a `User-Agent` containing hostname. TLS SNI is the endpoint hostname, not the client's. We do not enumerate `$env:COMPUTERNAME` / `hostname` anywhere in the payload pipeline.                                                |
| User-identity leaks via `$env:USER` / `$env:USERNAME` / `git config user.email`            | None of these are read by the telemetry path. The install-id is the only correlation key, and it is a freshly-generated UUID v4 with no derivation from username/hostname/timezone/etc.                                                                                                |
| Network calls block CLI exit on opt-in users                                                | Fire-and-forget background job (`Start-ThreadJob`) with a 2-second hard timeout. Job results are never `Receive-Job`'d back to the foreground; failures are swallowed. The CLI exits with its own exit code on its own schedule; the telemetry job lives or dies on its own.            |
| Proxy credentials leak via TLS                                                              | `Invoke-AvmHttp` does not source proxy credentials from any env var beyond what `[System.Net.WebRequest]::DefaultWebProxy` already does. We do not parse `$env:HTTP_PROXY` ourselves.                                                                                                  |
| Telemetry is sent from environments where the user did not consent (CI runners)            | Spec §21's "default off" is the primary defence. Plus: when `$env:CI` is set (well-known signal for CI environments) we *additionally* require an explicit per-repo `telemetry: true` to send. User-preference opt-in does not transfer to CI environments without per-repo confirmation. |
| Endpoint redirect / DNS hijack sends events to a third party                              | The endpoint URL is hardcoded at module-load time from `Avm.Authoring.psd1`'s `PrivateData`. No env var can override it. The instrumentation key is also hardcoded; a hijacked endpoint can't usefully consume the events.                                                              |
| GDPR Article 9 special-category data leakage                                                | Payload schema is closed; no field can carry health / religion / ethnicity / sexual-orientation / political views / biometrics / union membership. Install-id is randomly generated, not derived from any identifier.                                                                  |
| Reverse-engineering install-id → user identity                                              | A UUID v4 has 122 bits of randomness. There is no derivable mapping from install-id → user. The AVM team operating App Insights can correlate one install-id's events over time, but cannot resolve it to a person.                                                                    |

### Question 6 — when to send and how to handle failures

- **When**: on CLI exit, *after* the user-visible result has been written to stdout/stderr. Telemetry is fire-and-forget and must never block, delay, or contaminate the visible CLI output.
- **Mechanism**: `Start-ThreadJob` (built into pwsh 7.4, no extra dep) with the HTTP POST. The main thread does not wait for the job. The job has a 2-second hard timeout via the HTTP client itself, not via `Wait-Job` on the main thread.
- **Failure handling**: any exception from the job (network, DNS, TLS, 5xx, timeout) is swallowed. No retry. No log. No console output. The user must never see "telemetry failed to send" — that would itself be a UX bug.
- **Throttling**: no client-side throttling. The endpoint (App Insights) handles rate limiting. If a user runs `avm pre-commit` in a tight loop 1000× a minute, App Insights will rate-limit and we don't care.
- **Batching**: no client-side batching. Each invocation is one event. Simplifies the code, avoids the "what happens if the CLI is SIGKILL'd before the batch flushes" failure mode entirely.
- **Offline-mode interaction**: if `AVM_OFFLINE=1` is set, the telemetry job is never started in the first place. Same envelope as every other outbound call.
- **Verbose output**: `$env:AVM_TELEMETRY_DEBUG = '1'` (a third, debug-only env var, undocumented except in CONTRIBUTING.md) prints the would-be payload to stderr instead of sending. For developer use only; never sends real data when set.

### Question 7 — CLI telemetry vs module-deployment telemetry (the strict separation rule)

Two telemetry channels exist in the AVM contract. They must stay separate.

| Channel                           | Owner                                  | What it measures                                                                          | Emitter                                                                                          | Opt-out                                                                                                    |
| --------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| **Module-deployment telemetry**   | AVM Terraform module contract          | "module X was deployed once today" (Terraform `apply` against an instrumented AVM module) | `resource.modtm_telemetry.telemetry` in `main.telemetry.tf` (materialised by `mapotf transform`) | `var.enable_telemetry = false` in the consumer's Terraform config                                          |
| **CLI-tooling telemetry** (this design) | `Avm.Authoring` module                 | "the avm CLI was invoked once today" (`avm <verb>` on a developer workstation)            | `Avm.Authoring` itself, via App Insights ingestion POST                                          | spec §21 layered model (this Appendix § Question 4): `.avm/.disable` / `AVM_OFFLINE` / per-repo / per-user / env var |

**Why the separation matters:**

1. **Different consent populations.** A developer running `avm pre-commit` against a module is making a tooling choice. A user running `terraform apply` against that module is making a deployment choice. Conflating the two means the consent the user gave at deployment time silently applies to the developer's tooling — and vice versa.
2. **Different signals.** Tooling adoption is about *who is using our CLI*. Module deployment is about *what is being deployed*. Mixing them muddies both data sets.
3. **Different sustainment.** `Avm.Authoring` is owned by this repo; the `modtm` resource is owned by the AVM Terraform module contract. Changes to one must not require changes to the other.

**Concrete rules this implies:**

- `Avm.Authoring` MUST NOT read or write the `modtm` resource's UUID (`resource.random_uuid.telemetry`).
- `Avm.Authoring` MUST NOT influence the `var.enable_telemetry` value in any module under test.
- `Avm.Authoring`'s install-id and the `modtm` UUID are unrelated; they MUST NOT be derived from each other.
- The two endpoints MUST be different. `modtm` posts to Microsoft's telemetry endpoint (`modtm.azurewebsites.net` as of 2026-06); `Avm.Authoring` will post to a separate Application Insights resource owned by the AVM core team.
- `avm format` running `mapotf transform` against a module emits the module's `main.telemetry.tf` (because that's the AVM contract). That is *module-side* code-generation, not CLI-side telemetry. The mapotf-emitted file is shipped to the user's module, not invoked by the CLI.

### Question 8 — Phase placement and implementation slice outline

Per spec §21, the implementation is **Phase 3**. This appendix names the slices a future Phase 3 session should land. Each slice independently commits + ships.

| Slice            | Scope                                                                                                                                                       | Estimated size  |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| **Slice T-1** (config)   | `Set-AvmConfig` + `Get-AvmConfig` cmdlets. `<Config>/avm.config.json` schema with `telemetry: bool`. Per-repo `.avm/config.json` `telemetry` field. `Get-AvmConfig` resolves precedence layers from this Appendix § Question 4 and reports `TelemetrySource`. | ~150 LOC + tests |
| **Slice T-2** (install-id) | Install-id generation, storage, lifecycle. `New-AvmInstallId` + `Get-AvmInstallId` private helpers. `<Config>/install-id` file with mode `0o600` on POSIX.  | ~80 LOC + tests  |
| **Slice T-3** (payload)    | Payload schema + serialiser. Closed enum for `verb`. Field allow-list enforcement test (rejects any field not in the spec §21 list).                       | ~100 LOC + tests |
| **Slice T-4** (transport)  | `Send-AvmTelemetry` private helper. Fire-and-forget `Start-ThreadJob`. 2-second timeout. Swallow all failures. App Insights ingestion REST POST.            | ~120 LOC + tests |
| **Slice T-5** (wire-up)    | Public dispatchers (`Invoke-Avm`, `Invoke-AvmPreCommit`, etc.) call `Send-AvmTelemetry` on exit. CI environment requires per-repo opt-in.                   | ~50 LOC + tests  |
| **Slice T-6** (docs)       | CONTRIBUTING.md telemetry section. README.md three-line summary + link. `docs/user-guide.md` (once it exists) gets a "Telemetry" subsection.                | doc-only         |

**Why six small slices instead of one big one**: each slice is independently reviewable, and the threat model (Question 5) means we want each layer testable in isolation. Slices T-1, T-2, T-3, T-4 are independently shippable behind a feature flag (`PrivateData.TelemetryEnabled = $false` at module level); T-5 is the only slice that *activates* the channel.

### Recommended option (decisions locked by this appendix)

| Decision                       | Choice                                                                                                                                                                                |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ship CLI telemetry at all?     | **Yes** (opt-in, anonymous, narrow payload per spec §21).                                                                                                                              |
| Endpoint                       | **Azure Application Insights** (direct REST ingestion, no SDK).                                                                                                                       |
| Storage of install-id          | `<Config>/install-id`; UUID v4; mode `0o600` POSIX; user-deletable; never reset by the CLI.                                                                                            |
| Opt-in/out precedence          | `.avm/.disable` > `AVM_OFFLINE` > per-repo `.avm/config.json` > `AVM_TELEMETRY` env var > per-user `<Config>/avm.config.json` > **default off**. CI environments require per-repo opt-in. |
| Send timing                    | After user-visible output, fire-and-forget `Start-ThreadJob`, 2-second hard timeout, errors swallowed.                                                                                |
| Separation from `modtm`        | Strict. Different endpoints, different IDs, no read/write coupling. Question 7 rules are binding.                                                                                     |
| Phase placement                | **Phase 3**. Six slices (T-1 through T-6). Spec §21 is unchanged by this appendix.                                                                                                    |

### Trigger conditions to re-open this design

This appendix should be revisited if any of the following becomes true:

1. The AVM core team commits to **a different APM back-end** (Honeycomb, Datadog, self-hosted). Question 2's recommendation flips to (d) OpenTelemetry collector.
2. **GDPR or AVM legal review** rejects the "instrumentation key embedded in module" model. We'd need a per-tenant key handshake, which is a substantial design change (Question 2 + Question 5 both move).
3. **Volume exceeds App Insights free tier** for the AVM team's subscription. Question 2 moves to (b) Custom Azure Function with batching, or App Insights with sampling.
4. The user-base signals that **opt-in produces too low a signal to be useful**. We'd consider promoting to opt-out (default on, opt-out via the same precedence model). **Per spec §21 this would require an explicit spec change, not just an appendix update.**
5. A **second non-CLI emitter** appears in `Avm.Authoring` (e.g. a long-running daemon or watcher). Question 6's "one event per invocation" assumption breaks; we'd need batching.

### Deliberately deferred (do NOT pre-build before Phase 3)

- The endpoint URL + instrumentation key. Both block on AVM core team commitment. Hardcoding placeholders now would either (a) leak to a real endpoint we don't own (security incident) or (b) cause silent failures users would file bugs about.
- `Set-AvmConfig` / `Get-AvmConfig` cmdlets. They are Slice T-1; building them now without telemetry to gate would be scope creep.
- The `install-id` file. Generating it before telemetry ships is a privacy footgun (file appears, user wonders why, files a bug).
- `Start-ThreadJob` wiring in dispatchers. Slice T-5 only; landing earlier means dead code that confuses readers.
- CONTRIBUTING.md telemetry section. Slice T-6 only; documenting a feature that does not exist mis-leads contributors.
- A `tests/Pester/Unit/Private/Telemetry/` test tree. Zero production code = nothing to test.

### Open follow-ups

- **AVM core team commitment.** Need a specific Application Insights resource ID and instrumentation key (or an explicit "we're not doing telemetry"). Block on this for Phase 3 slice T-4.
- **Privacy / legal review** of the payload schema (Question 5's "no field can carry GDPR Article 9 data" assertion). Block on this for Phase 3 slice T-5 (the activation slice). Should be a short conversation given the closed-enum schema; capturing here so it doesn't get forgotten.
- **CONTRIBUTING.md update** in Slice T-6: cross-link to this Appendix and to spec §21.
- **README.md update** in Slice T-6: three lines on telemetry under a "Privacy" heading. Surface the opt-in semantics so users don't discover them by accident.
- **`docs/user-guide.md`** does not exist yet. When it lands (spec §22 calls for it), it gets a Telemetry subsection — captured here so the doc author doesn't omit it.
- **Cross-link from [Appendix F](#appendix-f-decision-dotnet-tool-packaging-as-a-phase-0-distribution-channel)** open-follow-ups: the line `"Telemetry design note still owes a write-up on whether (and how) we'd know if the pwsh prerequisite is hurting adoption"` is now answered by this Appendix G. A Phase 3 implementation of telemetry would let us observe the Appendix F re-open trigger.

---

## Appendix H. Decision: tool resolver and external version managers

**Status**: 2026-06-07. Resolves [plan §11](../docs/avm-consolidation-plan.md) open question via spec §23 OQ 4. Formalises existing behaviour as the documented contract — **no code changes required**.

### Context

Spec [§23 OQ 4](avm-implementation-spec.md) (line 670, verbatim):

> Tool resolver and external version managers. Honour `mise` / `asdf` / `tenv`'s shims when found on PATH and skip our own install for those tools, or always prefer our cache for determinism? Lean: prefer our cache, but accept the shim's version if it matches the lock exactly.

The plan reference is [§11 OQ table](avm-consolidation-plan.md) (not re-asked there; this Appendix closes the spec OQ directly). The decision is downstream of spec §10's [_Lookup order on every invocation_](avm-implementation-spec.md) (line 389) and the [_Get-AvmFolder_ resolver contract](avm-implementation-spec.md) at §7 (line 271, which calls out mise/asdf/tenv as the integration point for `AVM_HOME`).

### What `mise` / `asdf` / `tenv` concretely do

Three popular per-project version managers. All three install a binary on the user's PATH (a **shim**) whose only job is to dispatch to a per-version copy of the real tool stored under the manager's own data dir:

- `mise` (formerly `rtx`). Shim dir is `$XDG_DATA_HOME/mise/shims/` by default. Selects a version by walking up from cwd looking at `.mise.toml`, `.tool-versions`, and tool-specific files like `.terraform-version`. Tool versions cached under `$XDG_DATA_HOME/mise/installs/<tool>/<version>/`.
- `asdf`. Shim dir is `~/.asdf/shims/`. Selects via `.tool-versions`. Versions cached under `~/.asdf/installs/<tool>/<version>/`.
- `tenv`. Terraform-family-only (`terraform`, `terragrunt`, `tofu`, `atmos`). Shim dir is `~/.tenv/bin/`. Selects via `.terraform-version`, `.opentofuversion`, or `TENV_*` env vars. Versions cached under `~/.tenv/<tool>/<version>/`.

The shim is opaque to callers — `terraform --version` invoked against a mise shim execs through mise into the selected per-project version's binary and prints **that binary's** version banner. There is no `--shim` flag; users who haven't activated the manager (`mise activate` / `asdf` rc-source / `tenv` rc-source) see their normal PATH untouched.

### What the resolver does today

`Resolve-AvmTool` ([src/Avm.Authoring/Private/Tools/Resolve-AvmTool.ps1](../src/Avm.Authoring/Private/Tools/Resolve-AvmTool.ps1) lines 82–107) executes this order:

1. **Cache** — `<Data>/tools/<name>/<version>/<entrypoint>[.exe]` + `.verified` marker both present → return `Source='cache'`.
2. **PATH fallback** (only when caller passes `-AllowPathFallback`) — delegate to `Find-AvmToolOnPath`. If the entrypoint is on PATH **and** the binary's `--version` output contains a semver-shaped substring that string-equals the lock-pinned version (modulo leading `v`), return `Source='path'`.
3. **Otherwise** — throw `AvmToolException` code `AVM1014` with a remediation hint (`Run: avm tool install <name>`). Note that **the resolver deliberately does not auto-install** (lines 17–19 in the helper's docstring): auto-install is a separate, opt-in policy decision that the verb dispatcher owns. This is a deliberate deviation from spec §10 line 392 ("warn once and fall through to install"); a Phase 0 spike on the auto-install UX is tracked separately.

`Find-AvmToolOnPath` ([src/Avm.Authoring/Private/Tools/Find-AvmToolOnPath.ps1](../src/Avm.Authoring/Private/Tools/Find-AvmToolOnPath.ps1) lines 42–73):

- `Get-Command -CommandType Application -ErrorAction SilentlyContinue` resolves the binary on PATH. A shim binary is indistinguishable from a real binary at this layer; the shim's `Source` path (e.g. `~/.local/share/mise/shims/terraform`) is what we capture.
- `Invoke-AvmProcess <path> --version -TimeoutSec 10 -IgnoreExitCode` runs the binary. For a shim, the manager intercepts and execs the selected per-project binary, which prints its own version banner.
- The combined `StdOut + "`n" + StdErr` is regex-matched against `(?<![0-9.])(\d+\.\d+\.\d+(?:[\-+][0-9A-Za-z\.\-]+)?)`. First match wins; leading `v` stripped on both sides; comparison is case-sensitive (`-ceq`) on the normalised pair.
- If the `--version` invocation throws (e.g. shim segfaults), the `try/catch` at line 50–61 swallows it via `Write-Verbose`. `$detected` stays `$null`, `Matches` resolves `$false`, fall through to cache lookup (which throws `AVM1014` if there's no cache).

### Per-scenario audit

Walking ten realistic shim/non-shim scenarios against today's resolver. "Today" = `Resolve-AvmTool -Name <tool> -AllowPathFallback`.

| # | Scenario | Resolver picks | Behaviour correct? |
|---|----------|----------------|--------------------|
| 1 | mise installed + shim on PATH; project selects `1.9.5` (matches lock) | `Source='path'` (mise shim) | ✅ Exact-match accept, per spec lean |
| 2 | mise installed + shim on PATH; project selects `1.10.0` (mismatch) | `AvmToolException AVM1014` | ✅ Reject + clear remediation |
| 3 | mise installed + shim on PATH; **no project version selected** (`mise` errors on dispatch) | `AvmToolException AVM1014` | ✅ Graceful fallthrough via `try/catch` |
| 4 | mise installed; **`mise activate` not sourced**; shim dir not on PATH | `AvmToolException AVM1014` | ✅ Looks identical to "tool not installed" |
| 5 | asdf installed + shim on PATH; `.tool-versions` selects matching version | `Source='path'` (asdf shim) | ✅ Same as mise scenario 1 |
| 6 | tenv installed + shim on PATH (terraform); `.terraform-version` matches lock | `Source='path'` (tenv shim) | ✅ Same as mise scenario 1 |
| 7 | tenv installed for terraform, but `tflint` not shimmed (out-of-scope tool) | Normal PATH or cache for tflint | ✅ tenv only shims its supported tools |
| 8 | Direct binary on PATH (no version manager); version matches lock | `Source='path'` | ✅ Pre-existing behaviour |
| 9 | Both cache hit **and** PATH match exist | `Source='cache'` | ✅ Determinism wins — cache evaluated first |
| 10 | Lock entry declares `unsupportedPlatforms = @('windows-arm64')` and we're on that platform | `AvmToolException AVM1012` | ✅ Pre-check fires before cache or PATH |

All ten scenarios behave correctly with no code change. The shim's identity is irrelevant — we don't try to detect "this is a shim, not a real binary." We measure what the binary's `--version` reports, and if that string matches the lock, we trust it.

### Recommendation

**Option (b): formalise the current behaviour as the documented contract. No code changes.** The implementation already realises the spec §23 OQ 4 lean exactly.

The contract, in plain English: _"`-AllowPathFallback` accepts any binary on PATH whose `--version` output contains the lock-pinned semver. Shims from `mise` / `asdf` / `tenv` (or any other dispatcher) are transparently included because they execute through to a real binary whose `--version` banner is what we measure. The cache is always evaluated first, so a shim selecting a non-matching version never silently overrides a verified cache entry."_

### Why not the alternatives

- **(a) Always prefer cache; ignore PATH entirely (no `-AllowPathFallback`).** Loses the workstation UX where users already have mise/asdf set up with the right Terraform — we'd force them to re-download a redundant copy into our cache. Loses the CI UX where the runner image pre-installs tools at the matching version. Today's `-AllowPathFallback` opt-in already biases towards determinism (cache wins on ties); making PATH unreachable goes too far.

- **(c) Honour shims but skip our own install for shimmed tools.** Inverts the precedence (shim wins on tie). Two failure modes: (i) a project changes its `.terraform-version` mid-PR → silent binary swap, no reproducibility; (ii) a malicious shim wrapper could re-dispatch to an attacker-controlled binary whose `--version` lies. The cache-first ordering blocks both.

- **(d) Add a `-PreferShim` flag that flips precedence on demand.** Speculative — no concrete user need today. Adds API surface and a precedence-debugging matrix. Track as a re-open trigger; do not pre-build.

### Trigger conditions to re-open

This Appendix is correct as long as the assumptions below hold. If any one starts breaking, schedule a follow-up slice:

1. **Shim brands its own `--version` output.** If a future `mise`/`asdf`/`tenv` release prefixes the underlying tool's banner with its own version line (e.g. `mise 2026.5.4\nTerraform v1.9.5...`), the permissive regex picks the first semver — which would be the shim's version, not the tool's. Mitigation: per-tool regex or `MISE_QUIET=1` / `ASDF_VERBOSE=0` env hardening before the `--version` call.
2. **User-reported false-positive accept.** Shim claims correct version but binary is materially different (e.g. mise resolves to a patched fork at the same semver). Mitigation: extend the lock with an optional `sha256OnPath` field; verify the binary against it when PATH-resolving.
3. **`tenv` or `mise` adopts a non-semver version scheme.** e.g. nightly builds like `1.10.0-nightly-20260601`. The current regex matches the `1.10.0` prefix, which is the spec'd `[\-+]` suffix handling — should still work, but worth re-confirming if either tool changes its banner shape.
4. **New managed tool whose `--version` output doesn't match the regex.** The lock schema would need a per-tool `versionMatcher` extension, plus the resolver would have to dispatch on it. Same shape as `unsupportedPlatforms`.
5. **The auto-install policy spec deviation gets revisited.** The resolver throws on cache+PATH miss today, but spec §10 line 392 implies "fall through to install." If the verb dispatcher gains an `--auto-install` flag, the resolver may need a sibling `Resolve-AvmTool -AutoInstall` shape — handled then, not now.

### Deliberately deferred

- **`-PreferShim` flag** — speculative; no concrete user request. Would invert precedence and complicate the audit table.
- **Shim-brand allow-list** — overengineering for zero benefit. We measure the binary's reported version, not the shim's identity.
- **Auto-install when shim missing** — separate policy decision owned by the dispatcher, per spec §10 line 393's `AVM_AUTO_INSTALL=1` heuristic.
- **Shim chatter suppression (`MISE_QUIET=1` etc.)** — preemptive hardening for a trigger that hasn't fired. Re-evaluate when trigger (1) fires.
- **Per-call resolution cache** — `Find-AvmToolOnPath` runs `--version` afresh on every call. Cold mise shim startup is ~200ms; a chain that resolves 5 tools pays ~1s of latency at the boundary. Annoying but not wrong; optimise when a user reports it.

### Open follow-ups

- **Regression-test gap.** [tests/Pester/Unit/Private/Find-AvmToolOnPath.Tests.ps1](../tests/Pester/Unit/Private/Find-AvmToolOnPath.Tests.ps1) has 5 `It` blocks today covering the direct-binary happy paths against the live `pwsh` host. No coverage for the shim scenarios in the per-scenario table above. **Proposed slice** (≤30 lines net): add a `Describe 'Find-AvmToolOnPath external version manager shims'` block that mocks `Get-Command` + `Invoke-AvmProcess` (via `InModuleScope` + Pester `Mock`) to simulate scenarios 1, 2, and 3. Locks the contract against future regressions. Not bundled into this Appendix slice because (a) test-only work belongs in its own commit per slice cadence, and (b) it changes test surface, which the doc-only gate skips — landing them separately keeps each gate honest.
- **Spec §10 cross-link.** Spec §10 lines 389–393 don't yet say "shims work transparently." Append a one-line forward reference to this Appendix the next time spec §10 is edited (e.g. for the auto-install spike). Not worth a standalone slice.
- **CONTRIBUTING.md note.** When the user-facing CLI README gains a "version managers" section, link here. No `docs/user-guide.md` exists yet; track in the same Phase 3 doc-buildout window as Appendix G's `docs/user-guide.md` line.

## Appendix I. Decision: `hcl2json` adoption for narrow file-layout enforcement

> **UPDATE 2026-06-19 — SUPERSEDED. `hcl2json`/Slice R is dropped; the variables/outputs partitioning it would enforce is now done by mapotf.** When this audit was written (2026-06-03) the plan was: enforce avmfix behaviours #5 + #7 (variables/outputs file partitioning) as a **check-only** PowerShell rule on top of `hcl2json`, because avmfix didn't ship releases and the user preferred "flag rather than fix". As of 2026-06-19 both premises changed:
> 1. **mapotf now does #5 + #7 directly.** The governance `move_misplaced_blocks.mptf.hcl` config relocates non-canonical blocks out of `variables.tf` / `outputs.tf` to `main.tf`, and `sort_variables.mptf.hcl` / `sort_outputs.mptf.hcl` consolidate stray variable/output blocks into the canonical files (per-file `for_each` keyed on `mptf.range.file_name` preserves multi-file `variables.*.tf` layouts). This is a strict superset of the `hcl2json` two-rule scope — and it **fixes** rather than just flags.
> 2. **The "flag vs fix" tension is resolved by the upstream pattern, not by a read-only parser.** Upstream `pre-commit.porch.yaml` runs `mapotf transform` (auto-fix); `pr-check.porch.yaml` re-runs `mapotf transform` + `mapotf clean-backup` and then `git status --porcelain` — failing the PR if there is drift. So the canonical AVM model is **fix-in-pre-commit, flag-drift-in-pr-check**. Our engine reproduces both: `Invoke-AvmPreCommit` runs the transform; `Invoke-AvmPrCheck` runs it then asserts no working-tree drift.
>
> **Decision (2026-06-19): do NOT pin `hcl2json`, do NOT build Slice R, do NOT add the `Test-AvmRuleTerraformFileLayout` primitive or the `060`/`061` rules.** Building a parallel flag-only PowerShell reimplementation of a subset mapotf already covers would (a) duplicate effort, (b) diverge from the upstream contract, and (c) leave authors with a check that points at a problem mapotf would have auto-fixed. The `hcl2json` landscape analysis below is retained as a useful reference for any *future* read-only HCL-inspection need (e.g. docs-time variable-description extraction) — but it is no longer on the Terraform pre-commit critical path. See [Appendix J](#appendix-j-2026-06-19-terraform-pre-commit-ground-truth-refresh).

**Context.** [Appendix C](#appendix-c-decision-avmfix-replacement-strategy) catalogued ten avmfix behaviours. User decision **2026-06-03** narrows our enforcement scope to **two** — behaviour #5 (file-partitioning for `variables*.tf`: only `variable {}` blocks allowed) and behaviour #7 (file-partitioning for `outputs*.tf`: only `output {}` blocks allowed). The remaining eight (#1 resource-arg ordering, #2 module-arg ordering, #3 azapi overrides, #4 variable-attr ordering, #6 output-attr ordering, #8 locals alpha-sort, #9 `moved`/`removed` block ordering, #10 `terraform`-block ordering) become module-author choice. User scope language: *"I think we care about outputs\*.tf and variables\*.tf not containing anything else, but the rest of it can the authors choice. Could the hcl2json tool help to flag a failure for some of these scenarios rather than use attempting to fix them?"* This appendix answers that question. Read it before Slice R (the `Test-AvmRuleTerraformFileLayout` primitive + the two built-in rules that use it).

### What `hcl2json` is

- **Repository.** [`tmccombs/hcl2json`](https://github.com/tmccombs/hcl2json) — single-purpose CLI: parse an HCL file (or stdin), emit the parsed tree as JSON to stdout.
- **License.** Apache-2.0.
- **Implementation.** Go binary that wraps `hashicorp/hcl/v2` (currently `v2.24.0` — the same parser Terraform itself uses). Single static binary, no runtime dependencies, `go 1.25` toolchain at build time.
- **Distribution.** Pre-built GitHub Releases assets across all six platforms we target (`darwin_amd64`, `darwin_arm64`, `linux_amd64`, `linux_arm64`, `windows_amd64.exe`, `windows_arm64.exe`); `.tar.gz` / `.zip` archive variants also published; per-release `hcl2json_<ver>_checksums.txt` provides SHA256 for every asset. Verified against `v0.6.9` published 2026-04-04 (the current latest stable). Also packaged via Homebrew, MacPorts, mise, and Docker, but the GitHub Releases assets are what `tools.lock.psd1` would consume.
- **Surface area we'd use.** Bare invocation only: `hcl2json <file>` → JSON to stdout. `-simplify` (constant-folds expressions that don't reference unknown variables) and `-pack` (emit `hclpack` JSON instead of decoded JSON) exist but aren't relevant.
- **Output shape.** Top-level JSON object whose keys are the block types present in the file. For a conforming `variables.tf` the only top-level key is `"variable"`; any other key is a violation. Each key maps to an array of objects keyed by the block labels (e.g. variable name). Labels and bodies are mirrored verbatim from the parsed HCL.

### Per-behaviour audit (only the two in scope)

| # | Behaviour | Important? | `terraform fmt` covers? | Cheapest replacement |
|---|-----------|------------|--------------------------|----------------------|
| 5 | **`variables*.tf` file partitioning** — only `variable {}` blocks allowed; any other top-level block-type is a violation. | **Yes** (user-confirmed 2026-06-03; readability invariant — `cat variables.tf` should be only variables). | No — `terraform fmt` does not enforce block-type-per-file. | **(d) `hcl2json` + PowerShell rule** (see below). |
| 7 | **`outputs*.tf` file partitioning** — mirror of #5 for `output {}` blocks. | **Yes** (same rationale as #5). | No. | **(d) `hcl2json` + PowerShell rule**. |

### Replacement options compared

| Option | Verdict | Why |
|--------|---------|-----|
| **(a) PowerShell HCL parser (state machine)** | Reject | Brittle on heredocs / `${}` interpolation / escaped-quote labels / `//` + `/* */` comments. Write-once never-extend; reinventing a known-hard parser problem for a two-rule scope today. A second HCL-parsing need is foreseeable on the Terraform-side roadmap (variable-description extraction for docs, `validation {}` block detection, resource-label conventions) — going PowerShell-only here would compound the maintenance bill the moment that lands. |
| **(b) `terraform-config-inspect`** | Defer | HashiCorp Go library that returns a typed module representation (variables, outputs, resources, providers, calls). Strictly more capable than `hcl2json` for module-wide inspection, but it's a library — not a CLI. Adopting it needs the same build-and-host pipeline that [Appendix B](#appendix-b-decision-mapotf-replacement-strategy) parks behind a hosting decision. Overkill for syntactic block-type enumeration. Re-evaluate if a use case emerges that `hcl2json` can't serve. |
| **(c) `terraform` CLI built-ins** | Reject | No `terraform parse` command. `terraform fmt -check` only verifies whitespace + alignment. `terraform validate` needs `terraform init`. None enumerate top-level block types. |
| **(d) `hcl2json` + PowerShell rule on top** | **Adopt** | Generic HCL → JSON via the canonical `hashicorp/hcl/v2` parser. Read-only (no `terraform init`, no provider gRPC, no registry HTTPS). Pre-built single binary on all six platforms. Apache-2.0 with active maintenance and SHA256-checksummed releases. Slots into the existing `tools.lock.psd1` shape without disturbance. |

### Recommended option: **(d) adopt `hcl2json` as a pinned `tools.lock.psd1` dependency**

Concrete reasoning:

1. **Smaller blast radius than the avmfix-style binaries Appendix C audits.** No `terraform init` requirement. No provider plugin download. No registry HTTPS. No gRPC subprocess management. Pure file → JSON in a single Go process. The whole interaction surface is one CLI flag and one stdout consumer.
2. **Uses the canonical parser.** Wraps `hashicorp/hcl/v2 v2.24.0` directly — the same parser Terraform itself uses. Edge cases (heredocs, `${}` interpolation, escaped quotes in labels, `#` / `//` / `/* */` comments) are handled identically to Terraform; we get the correct answer for free, not by re-deriving HCL grammar in PowerShell.
3. **Forward-looking primitive.** Beyond today's two rules, the same JSON output supports future Terraform-side needs already foreshadowed on the roadmap: variable-description extraction for docs generation, `validation {}` block detection per AVM codex, resource-label convention enforcement, `for_each` / `count` presence detection per resource. Each is a one-line walk over the JSON tree, not a new parser.
4. **Bounded supply-chain cost vs Appendix B/C.** Single tool (vs avmfix's 37+ source files), no orchestration baggage (vs mapotf's cross-config dependency graph), upstream already ships releases (no release-workflow PR needed, no Azure-side build-and-host decision required). Slots into `tools.lock.psd1` with the same six-platform shape we already use for `terraform`, `conftest`, `terraform-docs`.
5. **Distinct chain from Slice H.** This is a **check-only** primitive that lives in `Invoke-AvmTerraformCheckConvention` (Slice C's chain), not `Format-AvmTerraformModule` (Slice H's chain). Slice H stays correct as `terraform fmt -recursive` alone — no avmfix-equivalent format step needed. The user's "flag a failure rather than attempting to fix" preference maps directly onto check-only semantics; auto-fix (block relocation) would require an HCL **writer**, which `hcl2json` is not.

### Slice R implementation outline (if option (d) holds)

1. **Pin `hcl2json` in `tools.lock.psd1`.** Six platforms (`darwin_amd64`, `darwin_arm64`, `linux_amd64`, `linux_arm64`, `windows_amd64`, `windows_arm64`), SHA256-verified against the upstream `hcl2json_<ver>_checksums.txt`. Version pin: latest stable at slice kick-off (currently `v0.6.9`). Extend [scripts/Update-AvmToolsLock.ps1](../scripts/Update-AvmToolsLock.ps1) with a `Get-Hcl2JsonEntry` helper (mirrors `Get-ConftestEntry` / `Get-TerraformDocsEntry`).
2. **Add `Get-AvmHclBlockTypes` private helper** under `src/Avm.Authoring/Private/Hcl/Get-AvmHclBlockTypes.ps1`. Resolves `hcl2json` via `Resolve-AvmTool -Name 'hcl2json' -AllowPathFallback:$AllowPathFallback`, invokes via `Invoke-AvmProcess` with argv `<hcl2json> <file>`, runs the stdout through `ConvertFrom-Json -AsHashtable`, returns the sorted set of top-level keys. Throws `AvmConfigurationException` on missing tool (caller surfaces as `skipped` via the standard chain semantics); throws `AvmProcessException` on parser failure.
3. **Add `Test-AvmRuleTerraformFileLayout` primitive** under `src/Avm.Authoring/Private/Rules/Primitives/`. `Parameters` shape: `@{ FilePattern = 'variables*.tf'; AllowedBlockType = 'variable' }`. Per matched file (walking the `AppliesTo` slots): run `Get-AvmHclBlockTypes`; pass iff the returned set is a subset of `@($AllowedBlockType)`; emit one `Issue` per offending file listing the unexpected block types and the file path.
4. **Add two built-in rules** under `src/Avm.Authoring/Resources/Rules/` (slot continues the numbering convention from Slice D's 010–050):
   - `060-variables-tf-only-variables.psd1` — `Kind = 'TerraformFileLayout'`, `FilePattern = 'variables*.tf'`, `AllowedBlockType = 'variable'`, `AppliesTo = 'root|examples|modules'`, `Severity = 'error'`.
   - `061-outputs-tf-only-outputs.psd1` — same shape with `FilePattern = 'outputs*.tf'`, `AllowedBlockType = 'output'`.
5. **Tests.** Unit cover for `Get-AvmHclBlockTypes` (canonical case, empty file, syntax-error file, missing tool, multiple top-level keys); the primitive (pass / fail / multi-file / `AppliesTo` walking); each built-in rule (round-trip via `Read-AvmRuleSet`). Integration: extend the existing Terraform integration smoke (`Invoke-AvmPreCommit.Terraform.Integration.Tests.ps1`) to pre-stage an `hcl2json` stub under `tests/fixtures/bin/` (same shape as `conftest.ps1`) and assert the two new rules pass against both fixture modules (which are upstream-compliant by construction).
6. **No wiring code change.** `Invoke-AvmTerraformCheckConvention` (Slice C) already discovers rules via `Read-AvmRuleSet` and dispatches by `Kind`. The new primitive registers via the same loader path as existing primitives. No changes to `Invoke-AvmPreCommit`'s chain. No changes to Slice H.

**Out of scope for Slice R:**

- Any auto-fix mode (block relocation to `main.tf`). User scope is explicit: flag, don't fix. A future toggle is reachable but not authorised, and `hcl2json` can't implement it anyway — it's a read-only parser, not a writer.
- The other eight avmfix behaviours. Module-author choice per 2026-06-03 scope decision.
- `Format-AvmTerraformModule.ps1` modifications. Slice H stays correct as the existing `terraform fmt -recursive` stub.
- `.tf.json` JSON-variant files (see open follow-up below).

### Open follow-ups before Slice R can land

1. **Re-confirm `hcl2json` latest stable at slice kick-off.** Current as of this audit: `v0.6.9` (published 2026-04-04, per `https://api.github.com/repos/tmccombs/hcl2json/releases/latest`). Confirm + re-fetch `hcl2json_<ver>_checksums.txt` immediately before pinning.
2. **Decide raw-binary vs archive pin.** Upstream publishes both per-platform raw binaries (simpler — no extract step) and `.tar.gz` / `.zip` archives (matches the shape of existing entries like `terraform-docs`). `tools.lock.psd1` schema accommodates both via the `archives` map. Default proposal: archives, for symmetry with sibling entries.
3. **Settle `.tf.json` handling.** Terraform supports `variables.tf.json` (the JSON-equivalent surface). `hcl2json` does not parse `.tf.json` — it is already JSON. Default proposal for Slice R: skip `.tf.json` files; surface as a per-rule `IncludeJsonVariant` boolean if a user ever cares. Track as a follow-up not blocking Slice R.
4. **Decide `FilePattern` glob semantics.** Upstream porch uses globbed filenames (`variables*.tf` matches `variables.tf` + `variables_extra.tf`). Default proposal for Slice R: glob — and surface the matched-file list in the `Issues` envelope so any false-positive is debuggable. Lock canonical-only behaviour later if module authors complain.
5. **Regression-test fixture gap.** Will need committed HCL fixtures under `tests/fixtures/hcl/` covering: canonical `variables.tf` (only `variable` blocks), mixed-file (`variable` + `locals`), heredoc-containing variable (parser stress test), syntax-error file (parser must fail loudly, not silently pass). The integration stub also needs a `Get-Hcl2JsonStubLauncher.ps1` helper alongside `Install-AvmStubLauncher.ps1`.

### What is deliberately deferred

- **Broader HCL-inspection use cases.** Variable-description extraction for docs generation, `validation {}` block detection per AVM codex, resource-label convention enforcement. All become one-line walks over the same JSON tree, but each new rule needs its own audit per the spirit of plan §2 ("mapotf + avmfix are AUDITED before implementation"). `Get-AvmHclBlockTypes` is the access pattern; extend to `Get-AvmHclModuleStructure` if a typed-by-block-kind shape is wanted, but only on demand.
- **The remaining eight avmfix behaviours** (`#1` resource-arg ordering, `#2` module-arg ordering, `#3` azapi overrides, `#4` variable-attr ordering, `#6` output-attr ordering, `#8` locals alpha-sort, `#9` `moved`/`removed` block ordering, `#10` `terraform`-block ordering). User-scoped out 2026-06-03 — module-author choice. Re-open via a new audit slice if downstream AVM module-review feedback signals local enforcement is missing.
- **`terraform-config-inspect` as a parallel primitive.** Strictly more capable than `hcl2json` for typed module-wide inspection (variables, outputs, resources by-type with attributes). Adopt only if a future use case can't be served by `hcl2json` + a JSON walk. Same build-and-host shape as [Appendix B](#appendix-b-decision-mapotf-replacement-strategy) if adopted.
- **Replacing Appendix B's mapotf chain with `hcl2json` + PowerShell rewriting.** Theoretically tractable for the `required_provider_versions` config (two attribute writes); not tractable for `main_telemetry_tf` (re-emits ~250 lines of HCL surface) without an HCL **writer**, which `hcl2json` is not. Not authorised; not on roadmap.
- **An auto-fix mode that moves stray blocks to `main.tf`.** Block relocation is the "fix" half of avmfix #5 + #7 — semantically clear (move every non-`variable` block from `variables.tf` to `main.tf`), but requires an HCL writer (`hcl2json` is read-only). Re-open if a contributor explicitly asks for the fix-on-commit ergonomics. Until then, the rule reports the offending file + block types and the contributor moves them by hand.

---

## Appendix J. 2026-06-19 Terraform pre-commit ground-truth refresh

This appendix is the **authoritative current state** for the Terraform pre-commit pivot. Appendices B, C, and I above carry dated update banners pointing here; where they disagree with this appendix, **this appendix wins**.

### J.1 What changed upstream (the pivot)

Three upstream facts changed since the 2026-05/2026-06 audits, reported by the user on 2026-06-19 and verified against `Azure/avm-terraform-governance` + `Azure/mapotf`:

1. **`avmfix` is deprecated and replaced by `mapotf`.** All block-reordering / hygiene / file-partitioning work (the full Appendix C 10-behaviour catalogue) is now done by `mapotf transform` against the hosted `mapotf-configs/pre-commit/*.mptf.hcl` bundle. avmfix is not adopted in any form. **Slice F is dead; Slice H stays closed.**
2. **`grept` is gone, replaced by "repo sync" in the governance repo.** Repo-level managed-file synchronisation now lives in `Azure/avm-terraform-governance`'s `tf-repo-mgmt/` PowerShell tooling — a **repo-scaffolding** layer, not a per-module pre-commit step. It is **out of scope** for `avm pre-commit` (see J.6). The custom-instruction "grept → PowerShell modules" is satisfied *upstream* by `tf-repo-mgmt`; our per-module convention rules (Slices C/D, already shipped) cover the per-module subset that does belong in pre-commit.
3. **`Azure/mapotf` now ships releases.** The Appendix B supply-chain blocker is dead — we pin the upstream release, no build-and-host.

**Net effect on the plan:** the only remaining engine for Terraform pre-commit parity is **`mapotf transform` (Slice G)**, now fully unblocked. **`hcl2json`/Slice R is superseded and dropped.**

### J.2 Canonical upstream chains (snapshot 2026-06-19)

**`pre-commit.porch.yaml` — 5 steps (fix-locally):**

1. `git config --local core.autocrlf false` (LF guard; our `.gitattributes` is authoritative, so N/A for us).
2. `mapotf transform --mptf-dir "$AVM_MPTF_URL" --tf-dir .` — `AVM_MPTF_URL` defaults to `git::https://github.com/Azure/avm-terraform-governance.git//mapotf-configs/pre-commit`.
3. `terraform -version` (tfenv install trigger; we already wire `Install-AvmTool terraform`).
4. `mapotf clean-backup --tf-dir .` — removes the `.tf.mptfbackup` files step 2 leaves behind.
5. `terraform-docs -c .terraform-docs.yml` over root + `examples/*` + `modules/*` (already wired via `Invoke-AvmTerraformDocs`).

> **There is NO `terraform fmt` in the canonical pre-commit** — mapotf's HCL writer handles formatting. Our `Format-AvmTerraformModule` (`terraform fmt -recursive`) is harmless and can stay, but it is not part of the upstream chain.

**`pr-check.porch.yaml` — full PR gate (flag-drift + policy):**

1. Fail if `git status --porcelain` is non-empty *(pre-condition; the working tree must be clean before checks)*.
2. terraform install.
3. **Lint (parallel):** `tflint` on root/examples/modules (configs downloaded from governance `tflint-configs`, `.override.hcl` merged via `hclmerge`) **+ check-mapotf-drift** (re-run `mapotf transform` + `mapotf clean-backup`, then fail if `git status --porcelain` shows drift) **+ check-docs-drift** (re-run terraform-docs, fail on drift).
4. **Well-architected (conftest):** per example → `terraform init` → `plan -out=tfplan` → `show -json` → download avmsec exemptions → `conftest` against APRL + `conftest` against avmsec (policies fetched via `go-getter` from `Azure/policy-library-avm`); honours `.e2eignore` skip + `pre/post.{sh,ps1}` hooks.

### J.3 The "fix vs flag" model (resolves the long-standing tension)

The earlier flag-only preference (which drove the `hcl2json` Slice Q/R audits) is satisfied **for free** by the upstream pattern:

- **pre-commit FIXES** — `mapotf transform` mutates files in place (leaving `.tf.mptfbackup`, removed by `clean-backup`).
- **pr-check FLAGS** — re-runs the *same* fixer, then asserts `git status --porcelain` is empty. Any divergence = the author didn't run pre-commit = PR fails.

So the AVM-canonical model is **fix-in-pre-commit, flag-drift-in-pr-check**. Our engine reproduces both halves (`Invoke-AvmPreCommit` transforms; `Invoke-AvmPrCheck` transforms + drift-checks). This is the decision the user signalled on 2026-06-19 by reporting the avmfix→mapotf pivot — but it does reverse the 2026-06-03 flag-only stance, so **confirm before building** (decision B below).

### J.4 `Azure/mapotf` v0.1.4 release — ready-to-pin facts

- Tag `v0.1.4`, published 2026-06-10. 7 assets: `checksums.txt` + 6 platform archives.
- Asset naming: `mapotf_0.1.4_{os}_{arch}.{ext}`, `ext` = `tar.gz` (darwin/linux), `zip` (windows) — the **mixed-archive** shape `tools.lock.psd1` already supports (same as `terraform-docs`).
- SHA256 checksums (captured 2026-06-19, ready for `tools.lock.psd1`):

  | Platform | Asset | SHA256 |
  | --- | --- | --- |
  | darwin/amd64 | `mapotf_0.1.4_darwin_amd64.tar.gz` | `43b580b480e6e86e54b0811f08c06a02fbcd0053c522b20548b352f82050df6d` |
  | darwin/arm64 | `mapotf_0.1.4_darwin_arm64.tar.gz` | `4b639d07d5d7cea5934104f2f7c1885d1f32011f5530b2e184b3ac91002e22a5` |
  | linux/amd64 | `mapotf_0.1.4_linux_amd64.tar.gz` | `3e7bc818c8b08e55f571f5b3561e40fa42807498f4f657fe38a5a4ceeda242cf` |
  | linux/arm64 | `mapotf_0.1.4_linux_arm64.tar.gz` | `a87462a7f9261bd9d10906bff543560ad58eff379f392958a0aa931933e4beca` |
  | windows/amd64 | `mapotf_0.1.4_windows_amd64.zip` | `9bf52956808a221423384e4a31eb665ddce24e6e6c06ffcf4d5a518f083491e4` |
  | windows/arm64 | `mapotf_0.1.4_windows_arm64.zip` | `40c810461af889ca5919b72d7c7ba5cb77887548cb9b95b7940bf3b24b5c4a79` |

  > Re-confirm the latest stable tag + re-pull `checksums.txt` at Slice-G kick-off; the table above is a 2026-06-19 snapshot, not a live pin.

### J.5 The governance config bundle (the `--mptf-dir` payload)

`Azure/avm-terraform-governance//mapotf-configs/pre-commit` — **nine** `.mptf.hcl` configs as of pin SHA `7f8c4ee4d68095310ddd8722f9cc27d32a0de82c` (2026-06-16):

`avm_headers_for_azapi`, `main_telemetry_tf`, `move_misplaced_blocks`, `order_module_attrs`, `order_resource_attrs`, `order_resource_meta`, `required_provider_versions`, `sort_outputs`, `sort_variables`.

These use mapotf's newer primitives — `reorder_attributes`, `sort_blocks_in_file`, `remove_block_element`, `move_block` — and collectively implement the full Appendix C catalogue (see the mapping in the Appendix C banner).

### J.6 Out of scope: `grept` → `tf-repo-mgmt`

`tf-repo-mgmt/` is **repo-governance scaffolding** (syncing managed files like `.github/`, `CODEOWNERS`, devcontainer config into module repos) — a different layer from per-module pre-commit. It is **not** on the pre-commit critical path and is **not** the next slice. Track it as a future "repo governance" phase if/when the user prioritises it. The per-module convention checks that *do* belong in pre-commit (file naming, required files/dirs) already shipped as Slices C/D.

### J.7 Slice G — the now-unblocked recipe

**Architecture: WRAP `mapotf`** (argv-array subprocess via `Invoke-AvmProcess`, exactly like `conftest`/`terraform-docs`/`terraform`/`tflint`). `Invoke-AvmTerraformTransform.ps1`'s own docstring already documents this design.

Steps:

1. **Pin `Azure/mapotf` v0.1.4 in `tools.lock.psd1`** — six platforms, the six SHA256s in J.4, mixed `archives` map (`tar.gz` + `zip`) with `urlTemplate` using `{version}`/`{os}`/`{arch}`/`{ext}` placeholders. Add a `Get-MapotfEntry` helper to `scripts/Update-AvmToolsLock.ps1` mirroring `Get-ConftestEntry`.
2. **Supply the configs (decision A — RESOLVED = vendor, see below).** The nine configs are **vendored** into `config/mapotf/pre-commit/` (top-level `config/`, kept out of the module tree) and mirrored from `Azure/avm-terraform-governance//mapotf-configs/pre-commit` at a pinned SHA via `scripts/Update-AvmMapotfConfig.ps1`. `Invoke-AvmTerraformTransform` resolves this in-repo path directly — no pinned-asset download, fully offline. See [`config/README.md`](../config/README.md).
3. **Implement `Invoke-AvmTerraformTransform`** — drop the `AvmConfigurationException` stub; resolve the mapotf binary + the configs asset; run `mapotf transform --mptf-dir <asset.Path> --tf-dir <Context.Root>` then `mapotf clean-backup --tf-dir <Context.Root>` via `Invoke-AvmProcess`; return the standard envelope (`Engine='terraform'`, `Tool='mapotf/<version>'`, `Status`, `Issues`). `[CmdletBinding(SupportsShouldProcess)]` — it mutates files.
4. **pr-check drift-check** — after transform + clean-backup, run `git status --porcelain` (or a `git diff --quiet` equivalent) scoped to `Context.Root`; non-empty ⇒ `Status='fail'` with the drifted files as `Issues`. This is the "flag" half of J.3.
5. **Tests** — promote `Invoke-AvmTerraformTransform.Tests.ps1` from stub-only (mock `Invoke-AvmProcess`; assert argv shape, clean-backup call, missing-asset → `AvmConfigurationException` → `skipped`); add a `mapotf` stub under `tests/fixtures/bin/` mirroring `conftest.ps1`; extend the Terraform integration smoke.
6. **Wire** into the `Invoke-AvmPreCommit` Terraform chain (transform step) and the `Invoke-AvmPrCheck` chain (transform + drift-check).

**Two strategic decisions — both RESOLVED with the user 2026-06-19:**

- **(A) How to supply the configs — RESOLVED = vendor.** The user directed (2026-06-19): *"We want to move the mapotf configs into this repo in a separate folder to the powershell module… until we can release this module we'll need to keep the configs in sync and then we'll be able to delete them from the avm-terraform-gov repo."* So the configs are **vendored** into a top-level `config/mapotf/pre-commit/` (not `src/Avm.Authoring/Resources/`, because they're destined to become the canonical copy and are kept separate from the module), mirrored at pin `7f8c4ee4d68095310ddd8722f9cc27d32a0de82c` via `scripts/Update-AvmMapotfConfig.ps1` (`-Check` for the CI drift gate). This supersedes the (i) pinned-asset recommendation — vendoring is offline by construction, needs no descriptor, and is the path to canonical ownership. Landed as the `slice-g1-vendor-configs` slice. See [`config/README.md`](../config/README.md).
- **(B) fix-in-pre-commit + drift-check-in-pr-check semantics (J.3) — RESOLVED = follow upstream.** The user confirmed (2026-06-19, *"yes proceed"*) the upstream-canonical model: `pre-commit` **fixes** via `mapotf transform`, `pr-check` **flags drift** via re-transform + `git status --porcelain`. This consciously reverses the 2026-06-03 flag-only preference.

With (A) and (B) resolved, the only remaining Slice G work is the **engine** (pin the mapotf binary, implement `Invoke-AvmTerraformTransform` against `config/mapotf/pre-commit/`, add the pr-check drift-check, tests, wiring) — tracked as `slice-g-transform`. The config-supply half is done.
