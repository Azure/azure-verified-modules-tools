# Repository management

This area owns the managed files, scheduled repository synchronization, and
operator-driven repository creation used by AVM Terraform repositories, plus
shared Bicep/Terraform metadata tooling.

[Module catalog sync](module-catalog/README.md) owns the generated CSV/JSON
indexes and tier membership updates. [Metadata file creation](module-metadata/README.md)
uses existing indexes and source without intermediate approval files.
Terraform supports this operation in its sync; Bicep files are added directly
to the module repository.

Repository sync and [repository creation](repository-creation/README.md) are
intentionally independent. New repositories initialize their own metadata from
explicit creation inputs before publishing module files. The existing tooling
inventory PR update remains a separate compatibility step.

[State infrastructure and TME cutover](repository-sync/README.md) documents
the independent state identity, deployment, migration, and rollback.

The current snapshot came from the legacy Terraform governance repository at commit
`59078e1bde61af0a5881331d2d26a41f791f5624`. This is an interim home until
these capabilities move to Proxima.

## Terraform CODEOWNERS

Repository sync renders [CODEOWNERS.template](repository-sync/CODEOWNERS.template)
from [repository configuration](repository-config/config.json). Matching groups,
including the wildcard `default` group, contribute `codeOwnersTeams` for the
default `*` rule and `codeOwnersFileProtectionTeams` for the final
`.github/CODEOWNERS` rule. Teams are deduplicated and qualified with the target
organization; a group targeting one repository can supply its specific owners.
An empty team list omits that rule.

The generated file replaces stale content or creates a missing file after
`avm pre-commit` succeeds, in the same temporary checkout and publication flow.
Plan-only runs show local drift without publishing. Edit the configuration or
template here, not the generated files in individual module repositories.

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
