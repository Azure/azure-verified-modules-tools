# Repository management

This area owns the managed files, scheduled repository synchronization, and
operator-driven repository creation used by AVM Terraform repositories.

Repository sync and repository creation are intentionally independent.

The current snapshot came from the legacy Terraform governance repository at commit
`59078e1bde61af0a5881331d2d26a41f791f5624`. This is an interim home until
these capabilities move to Proxima.

## Staged managed-file rollout rings

Managed files live in [`Azure/azure-verified-modules-managed-files`](https://github.com/Azure/azure-verified-modules-managed-files)
under `terraform/files`. A repository receives `root` plus every overlay declared
by the repository groups it belongs to, applied in `order`; higher `order` wins.
The narrowest ring therefore carries the highest `order`.

| Ring | Directory | Repositories | `order` |
| ---- | --------- | ------------ | ------- |
| 0 | `terraform/files/canary-ring-0` | `avm-ptn-example-repo` only | 20 |
| 1 | `terraform/files/canary-ring-1` | the ten canary repositories | 10 |
| – | `terraform/files/root` | every managed repository | base |

Author a risky change in `canary-ring-0`, then promote it a ring at a time:

```pwsh
git mv terraform/files/canary-ring-0/<path> terraform/files/canary-ring-1/<path>
git mv terraform/files/canary-ring-1/<path> terraform/files/root/<path>
```

A file's directory is the only thing that selects its audience, so promotion
never edits the repository group config and never changes cohort membership.

**Promote by moving, never by copying.** Overlays beat `root`, so a copy left
behind in a higher ring keeps overriding `root` for that ring's repositories. The
symptom is that every repository picks up the change except the one used to test
it.

To stop shipping a file everywhere, add it to the `deletedFiles` array of the
relevant group in `terraform/config/managed-files.json`. That both suppresses the
file and removes any copy already present in the target repository.
