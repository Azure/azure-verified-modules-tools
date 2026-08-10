# Copilot instructions for `azure-verified-modules-tools`

This repo uses [`AGENTS.md`](../AGENTS.md) as the canonical agent contract. Read it first.

The short version of the protocol:

1. **Read [`docs/progress.md`](../docs/progress.md) before doing anything else** — it defines the progress protocol. Then read active or blocked files under `docs/progress/`. Closed legacy work lives in [`docs/progress-archive.md`](../docs/progress-archive.md).
2. **Read [`docs/avm-implementation-spec.md`](../docs/avm-implementation-spec.md) and [`docs/avm-consolidation-plan.md`](../docs/avm-consolidation-plan.md)** before writing or refactoring code that touches the module surface.
3. **Create or update one `docs/progress/YYYY-MM-DD-<descriptive-slug>.md` file per slice.** Record status, dates, branch, outcome, checklist, validation, and blockers or dependencies. Never allocate sequential `F###` identifiers or maintain a shared mutable index.
4. **Use `./build.ps1` for build / test**; never invent ad-hoc commands. The local gate is `./build.ps1 pre-commit` (layout + lint + test + component).
5. **Commit and push after every slice.** Once `./build.ps1 pre-commit` is green (or for doc-only edits), stage with `git add -A`, write a Conventional-Commits message (`feat(area): …`, `fix(area): …`, `docs: …`, `test(area): …`, `refactor(area): …`), commit, then push the current feature branch. Never push to `main`, never `--force`, never open or merge a pull request without explicit user instruction. See **Commit & push protocol** in `AGENTS.md` for the full rules.

When in doubt, defer to `AGENTS.md` and the spec — they win over your prior assumptions about how PowerShell modules "usually" look.
