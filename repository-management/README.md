# Repository management

This area owns the managed files, scheduled repository synchronization, and
operator-driven repository creation used by AVM Terraform repositories.

Repository sync and repository creation are intentionally independent.

The current snapshot came from the legacy Terraform governance repository at commit
`59078e1bde61af0a5881331d2d26a41f791f5624`. This is an interim home until
these capabilities move to Proxima.

## Staged managed-file rollout rings

Managed files are composed from `managed-files/files/root` plus any overlay
directories declared by the repository groups a repository belongs to. Later
overlays win, ordered by each group's `managedFilesOrder`. That gives three
rollout rings for a risky change:

| Ring | Directory                       | Repositories                | `managedFilesOrder` |
| ---- | ------------------------------- | --------------------------- | ------------------- |
| 1    | `managed-files/files/canary-tooling` | `avm-ptn-example-repo` only | 20 |
| 2    | `managed-files/files/canary`         | the ten canary repositories | 10 |
| 3    | `managed-files/files/root`           | every managed repository    | n/a |

Author the file in `canary-tooling`, then promote it a ring at a time:

```pwsh
git mv managed-files/files/canary-tooling/<path> managed-files/files/canary/<path>
git mv managed-files/files/canary/<path> managed-files/files/root/<path>
```

A file's directory is the only thing that selects its audience, so promotion
never edits `config.json` and never changes cohort membership. Both overlay
pointers are wired permanently, and an overlay containing only `.gitkeep`
contributes no files.

**Promote by moving, never by copying.** Overlays beat `root`, so a copy left
behind in a lower ring keeps overriding `root` for that ring's repositories. The
symptom is that every repository picks up the change except the one used to test
it.

`excludedManagedFiles` suppresses a path for a repository group. It stops the
file being shipped or updated; it does not delete a copy already present in the
target repository. Removing a file everywhere requires an entry in
`managed-files/config/deprecated-files.json`.
