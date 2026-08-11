# Staged managed-file rollout rings

Status: in-progress
Started: 2026-08-11
Branch: `jaredfholgate-canary-rollout-rings`

## Outcome

Managed-file changes can be proved on a single repository before they reach the
ten canary repositories, and before they reach everything. The legacy
`repository-management/managed-files/` shim is retired now that Avm.Authoring
0.8.0 resolves managed files from the dedicated repository.

## Context

The previous slice moved managed files to
[`Azure/azure-verified-modules-managed-files`](https://github.com/Azure/azure-verified-modules-managed-files)
but left the canary overlay unwired: the `canary` repository group declared no
`managedFiles`, so no overlay directory was ever applied. It also retired the
`canary-tooling` file group, which had only ever existed as a `.gitkeep` and a
`managedFilesAdditional` pointer, never as a repository group.

Two rings are reinstated, with names that state the audience rather than the
tooling:

| Ring | File group | Repositories | `order` |
| ---- | ---------- | ------------ | ------- |
| 0 | `canary-ring-0` | `avm-ptn-example-repo` only | 20 |
| 1 | `canary-ring-1` | the ten canary repositories | 10 |
| – | `root` | every managed repository | base |

The narrowest ring carries the highest `order` because higher `order` wins, so
the ring number ascends as the audience widens while `order` descends.

`root` keeps its name. `default` would collide with the repository group of that
name which points at it, and `prod` would wrongly imply the rings are not
production — `avm-ptn-example-repo` is a live repository.

The `canary` topic value is unchanged. Topics are applied authoritatively by
Terraform, so renaming the value would churn topics on ten live repositories for
no benefit.

`canary-ring-1` and `azure-landing-zones` both carry `order: 10`. The two groups
share no repositories, so the tie is unreachable.

## Checklist

- [x] Rename the `canary` file group to `canary-ring-1` in the managed files
      repository, and add `canary-ring-0`.
- [x] Seed `canary-ring-0` with the agentic issue-triage workflow, ported from
      tools PR #52 (originally `Azure/avm-terraform-governance` PR #527 by
      @myaschmitz, whose repository is now archived). Both blobs match the
      source byte-for-byte.
- [x] Wire both rings as repository groups in
      `repository-management/repository-config/config.json`.
- [x] Delete `repository-management/managed-files/`.
- [x] Document the rings and the promote-by-moving rule in
      `repository-management/README.md`.
- [x] Invert the layout test that guarded the shim so it asserts the tree is
      gone.
- [ ] `./build.ps1 pre-commit` green.
- [ ] Update the Proxima docs page for the rename and for the canary path now
      being wired.

## Validation

Pending.

## Dependencies

- Managed files repository PR:
  <https://github.com/Azure/azure-verified-modules-managed-files/pull/7>
- Supersedes tools PR #58, which staged the same rings against the legacy
  `repository-management/managed-files/` tree.
- Carries the content of tools PR #52 into `canary-ring-0`.
