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

- **Telemetry design note** still owes a write-up on whether (and how) we'd know if the `pwsh` prerequisite is hurting adoption. Without telemetry the user-research trigger above is unobservable.
- When Phase 3 starts and Option 3 is activated, **this appendix should be promoted to a Phase 3 spec section** (or a sibling appendix `Appendix F-1`) covering the actual distribution-channel cut-over plan, not a defer-or-not decision.