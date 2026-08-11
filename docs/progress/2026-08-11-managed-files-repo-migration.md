# Managed files repository migration

**Status**: complete
**Started**: 2026-08-11
**Completed**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-managed-files-repo-migration`

## Outcome

Move the managed-file overlays out of this repository into
`Azure/azure-verified-modules-managed-files` and rework the repository
configuration onto a schema that separates repository grouping (which stays
here, relocated to `repository-management/repository-config/config.json`) from
file-group definition (which moves to the new repository).

Repository grouping keeps `repositoryGroups`, but every group now declares its
own `teams`, and a `default` group matching `repositories: ["*"]` replaces the
implicit `all` pseudo-group along with the root-level `codeOwners`, `topics`,
and `workloadIdentityFederationSubjectClaimOverrides` blocks. The wildcard is
the only source of truth for "applies to every repository", so the engine
carries no hardcoded fallback file group.

File-group definition moves to `terraform/config/managed-files.json` in the new
repository, where each file group owns its `deletedFiles`. That folds in both
the repository-scoped `excludedManagedFiles` and the global
`deprecated-files.json`, and makes deletions order-aware so a higher-order file
group can reinstate a path deleted by a lower-order one.

`repository-management/managed-files/` is retained unchanged as a compatibility
shim. `avm pre-commit` imports the published `Avm.Authoring` from the gallery,
not the in-repo source, so every module repository resolves managed files from
that folder until the next release ships. A follow-up pull request deletes it
once the release is out. The tree is therefore duplicated between this
repository and the new one, and can drift, until that follow-up lands.

## Checklist

- [x] Rewrite `config.json` onto the `default`-group schema.
- [x] Relocate the configuration to
      `repository-management/repository-config/config.json`.
- [x] Rename `managedFilesAdditional` to `managedFiles` and `managedFilesOrder`
      to `order`.
- [x] Dissolve `teamMappings` into per-group `teams`.
- [x] Support `repositories: ["*"]` wildcard group matching.
- [x] Drop the unused overlay and exclusion resolution from
      `RepositoryConfig.ps1` so the engine is the single resolver.
- [x] Resolve file groups and order-aware `deletedFiles` from the new
      repository's `managed-files.json` in `Sync-AvmManagedFile.ps1`.
- [x] Point the default managed-files source at the new repository.
- [x] Retire the `canary-tooling` file group.
- [x] Check the new repository out in the repository-sync workflow.
- [x] Update the affected Pester tests and `Test-RepositoryConfig.ps1`.
- [x] Update the changelog.
- [x] Complete the repository validation gate.
- [x] Commit, push, and open the pull request.

## Validation

- `./build.ps1 pre-commit` green end to end: layout OK, lint OK, 897 unit tests
  passed with 0 failed and 7 skipped, 28 component tests passed with 0 failed.
- `Test-RepositoryConfig.ps1` runs green against the relocated configuration.
- A differential harness compared the old and new `Resolve-RepositorySettings`
  across all eight repository groups and reported identical output for every
  consumed key.

## Blockers or dependencies

Depends on `Azure/azure-verified-modules-managed-files` pull request 6, which
removes the empty `canary-tooling` file group and hoists `scripts/` to the
repository root.

Followed by a pull request deleting `repository-management/managed-files/`,
which can only land after the next `Avm.Authoring` release reaches the gallery.
