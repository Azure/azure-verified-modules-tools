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
