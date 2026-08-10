# AVM CLI progress

This is the stable entry point for delivery status. Mutable work records live
as independent files under [`docs/progress/`](progress/) so concurrent branches
do not edit one shared checklist.

## Starting work

1. Read active or blocked slice files under `docs/progress/`.
2. Read [`avm-implementation-spec.md`](avm-implementation-spec.md) and
   [`avm-consolidation-plan.md`](avm-consolidation-plan.md) for implementation
   rules and sequencing.
3. Create one file named `YYYY-MM-DD-<descriptive-slug>.md` for the new slice.
   Do not allocate a sequential `F###` identifier and do not maintain a shared
   index.

Each slice file records:

- `Status`: `in-progress`, `blocked`, or `complete`
- `Started` and `Updated` dates
- the working branch
- outcome, checklist, validation, and blockers or dependencies

Update only the slice file owned by the current branch. Keep completed files in
place as the audit trail. If work is deliberately handed to another branch,
record the takeover in that same file before the new branch edits it.

## Finding current work

```pwsh
Get-ChildItem ./docs/progress -Filter '*.md' |
    Select-String -Pattern '^\*\*Status\*\*: (in-progress|blocked)$'
```

The checklist used before this convention was adopted is preserved in
[`legacy-checklist-through-2026-08-10.md`](progress/legacy-checklist-through-2026-08-10.md).
Older closed workstreams remain in
[`progress-archive.md`](progress-archive.md).
