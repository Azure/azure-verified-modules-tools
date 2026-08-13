# Repository management

This area owns the managed files, scheduled repository synchronization, and
operator-driven repository creation used by AVM Terraform repositories.

Repository sync and repository creation are intentionally independent.

The current snapshot came from the legacy Terraform governance repository at commit
`59078e1bde61af0a5881331d2d26a41f791f5624`. This is an interim home until
these capabilities move to Proxima.

## Staged managed-file rollout rings

Managed files live in [`Azure/azure-verified-modules-managed-files`](https://github.com/Azure/azure-verified-modules-managed-files)
under `terraform`, one folder per file group. A repository receives `root` plus
every overlay declared by the repository groups it belongs to, applied in
`order`; higher `order` wins. The narrowest ring therefore carries the highest
`order`.

| Ring | Directory | Repositories | `order` |
| ---- | --------- | ------------ | ------- |
| 0 | `terraform/canary-ring-0` | `avm-ptn-example-repo` only | 20 |
| 1 | `terraform/canary-ring-1` | the ten canary repositories | 10 |
| – | `terraform/root` | every managed repository | base |

Author a risky change in `canary-ring-0`, then promote it a ring at a time:

```pwsh
git mv terraform/canary-ring-0/<path> terraform/canary-ring-1/<path>
git mv terraform/canary-ring-1/<path> terraform/root/<path>
```

A file's directory is the only thing that selects its audience, so promotion
never edits the repository group config and never changes cohort membership.

**Promote by moving, never by copying.** Overlays beat `root`, so a copy left
behind in a higher ring keeps overriding `root` for that ring's repositories. The
symptom is that every repository picks up the change except the one used to test
it.

Each group folder also carries a reserved `_config.json` that is never synced
into a target repository. It declares the group's `description`, its
`deletedFiles`, and its `managedLines`. To stop shipping a file everywhere, add
it to the `deletedFiles` array in the relevant group's `_config.json`. That both
suppresses the file and removes any copy already present in the target
repository.
