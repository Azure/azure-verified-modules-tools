# Copilot instructions

This is the repository's only agent instruction file. Read
[`docs/quality-spec.md`](../docs/quality-spec.md) before changing code. It is
the single source of truth for the module's purpose, architecture, security
controls, coding rules, testing model, and release practices.

## Working rules

- Work on the current feature branch. Never push to `main` or force-push.
- Do not create progress, planning, handoff, or decision-history documents.
  Git history, issues, and pull requests record completed work. Update the
  quality spec only when the repository's current mandatory contract changes.
- Keep changes focused and preserve existing behavior unless the requested
  change deliberately alters it.
- Use PowerShell 7.4+ and the existing helpers and patterns. Do not introduce
  Bash scripts.
- Every exported function must have complete comment-based help covering its
  purpose, behavior, parameters, examples, and outputs.
- Keep inline comments rare. Record mandatory, repository-wide implementation
  practices in `docs/quality-spec.md`; use an inline comment only when the code
  cannot make a necessary local constraint clear.

## Build and generated documentation

Use only the repository build entry point:

```pwsh
./build.ps1 layout
./build.ps1 lint
./build.ps1 test
./build.ps1 component
./build.ps1 docs
./build.ps1 docs-check
./build.ps1 pre-commit
```

`./build.ps1 docs` regenerates `docs/reference/` from the comment-based help
on every exported cmdlet. Run it whenever an exported function, parameter, or
help block changes, then commit the generated Markdown.

`./build.ps1 docs-check` is non-writing and fails when generated pages are
missing, stale, or unexpected. It runs as part of `pre-commit`, `ci`, `ci-tests`,
`ci-unit`, and `ci-coverage`, so pull-request checks fail until the reference is
regenerated.
Never hand-edit generated reference pages.

Run `./build.ps1 pre-commit` before committing code changes. Documentation-only
changes that do not affect generated cmdlet reference may skip the full gate.

## Mandatory implementation practices

- PowerShell Core only; support Windows, Linux, and macOS.
- Use LF and UTF-8 without BOM.
- Use approved verbs and the `Avm` noun prefix for exported functions.
- Use typed exceptions and explicit errors; do not hide failures or return
  success-shaped fallbacks.
- Invoke subprocesses only through `Invoke-AvmProcess` with argument arrays.
- Route HTTP through the shared networking helpers and preserve checksum,
  certificate, offline, retry, and source-host controls.
- Use `[CmdletBinding(SupportsShouldProcess)]` for state-changing cmdlets.
- Preserve module and manifest casing exactly.
- Add tests at the smallest appropriate layer and keep check modes non-writing.
- GitHub Actions workflow names use `<Group>: <Name>`; job and step display
  names use sentence case without an `[AVM]` prefix.

## Commit and pull-request protocol

- Stage the complete focused change, including generated docs.
- Use a Conventional Commit with a first line no longer than 72 characters.
- Include the required Copilot commit trailers supplied by the session.
- Push the current feature branch after the local gate passes.
- Reuse an existing open pull request for the branch. If none exists, open one
  against `main`. Do not merge or close it without explicit user instruction.
