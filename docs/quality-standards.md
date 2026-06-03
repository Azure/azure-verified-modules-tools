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
