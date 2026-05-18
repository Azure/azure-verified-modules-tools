# Copilot instructions for `azure-verified-modules-tools`

This repo uses [`AGENTS.md`](../AGENTS.md) as the canonical agent contract. Read it first.

The short version of the protocol:

1. **Read [`docs/progress.md`](../docs/progress.md) before doing anything else** — it's the living checklist that tells you what's done, what's blocked, and what to pick up next.
2. **Read [`docs/avm-implementation-spec.md`](../docs/avm-implementation-spec.md) and [`docs/avm-consolidation-plan.md`](../docs/avm-consolidation-plan.md)** before writing or refactoring code that touches the module surface.
3. **Update `docs/progress.md` immediately** when you start a slice (`[ ]` → `[~]`), finish one (`[~]` → `[x]`), discover a new must-do (add under the right phase), or hit a blocker (append to **Known issues**). Always bump the `Last updated` line.
4. **Use `./build.ps1` for build / test**; never invent ad-hoc commands. While `./build.ps1 lint` is broken (see Known issues), gate work with `./build.ps1 layout` + `./build.ps1 test`.
5. **Never `git commit`, `git push`, or open a PR without explicit user instruction.** The user drives version control.

When in doubt, defer to `AGENTS.md` and the spec — they win over your prior assumptions about how PowerShell modules "usually" look.
