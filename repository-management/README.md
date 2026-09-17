# Repository management

This area owns the managed files, scheduled repository synchronization, and
operator-driven repository creation used by AVM Terraform repositories, plus
shared Bicep/Terraform metadata tooling.

[Module catalog sync](module-catalog/README.md) owns the generated CSV/JSON
indexes and source CSV row-removal protection. [Metadata file creation](module-metadata/README.md)
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

## Test tenant selection

`testTenant` accepts only `legacy` or `bami`. The
[Terraform configuration](repository-config/config.json) defaults to `legacy`
and selects `bami` for the existing canary groups without changing their
membership or managed-file promotion. Higher `order` wins; later declaration
wins a tie. Missing settings retain `legacy`.

[Bicep configuration](bicep-test-tenant-config/config.json) lives here, not in
the Bicep repository. Its `moduleGroups` use `name`, `order`, `modules`, and
only one behavioral setting: `testTenant`. Initially only
`avm/res/dev-test-lab/lab` selects `bami`.

The BAMI publisher stages this complete nonsecret bundle in the Tools `avm`
environment. There is one current BAMI tenant, not a profile catalog.

| Variable | Purpose |
| --- | --- |
| `TEST_BAMI_TENANT_ID` | Candidate tenant |
| `TEST_BAMI_CONTROLLER_CLIENT_ID` | Repository-identity provisioning only |
| `TEST_BAMI_ADMIN_SUBSCRIPTION_ID` | Subscription holding repository identities |
| `TEST_BAMI_SUBSCRIPTION_IDS` | Exactly 28 unique `{name,id}` objects, encoded as JSON |
| `TEST_BAMI_MANAGEMENT_GROUP_ID` | Test management-group name |
| `TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME` | Existing repository-identity resource group |
| `TEST_BAMI_BICEP_CLIENT_ID` | Separate Bicep execution identity |
| `TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID` | Bicep persistent-resource subscription |

Admin and Persistent must be different subscriptions, and neither may appear
in the disposable test pool. The shared Bicep-only guard also rejects
Persistent overlap without copying Admin into the Bicep projection.

Terraform sync uses dedicated per-repository identities, never the controller
or Bicep client as a test identity. It replaces the existing repository
**secrets** `ARM_TENANT_ID`, `ARM_CLIENT_ID`, and `TEST_SUBSCRIPTION_IDS`; writing
same-named variables would not override the current consumers' secrets.
Unselected repositories retain their existing settings. See the
[candidate state and execution prerequisites](repository-sync/README.md#bami-candidate-identities).

Bicep variable sync copies only the five execution fields: tenant, Bicep
client, subscription pool, management group, and persistent subscription.
It leaves all legacy values untouched. For temporary BAMI testing, it derives
the repository variable `TEST_BAMI_MODULE_PATHS` from the central groups and
publishes that JSON array last:

```json
["avm/res/dev-test-lab/lab"]
```

The array contains only canonical module paths whose resolved `testTenant` is
`bami`. Missing or `[]` means legacy. Consumers directly check array membership
for their canonical module path and alias the existing execution variables;
there is no runtime Tools resolver action, consumer routing file, or per-module
workflow-file synchronization. Selecting `legacy` in the central groups removes
the path from the array. The five execution values remain strings, including
the compact subscription-pool JSON.

Tools rejects malformed arrays, duplicate/noncanonical paths, and incomplete
candidate bundles before publication. Reserved-subscription and identity
separation checks are unchanged. These checks do not prove that separately
published source values came from the same publication; a complete but mixed
bundle may still pass structural validation.
Successful variable readback is not proof of Azure authentication or permissions.
Bicep activation also requires its own execution-identity federated credential
for the intended subject
`repository_owner_id:6844498:repository_id:447791597:environment:avm-validation`.
That credential and runtime login remain unproved; do not reuse the
Tools-controller credential or enable publication to bypass an unverified
authentication prerequisite.

### Bicep variable publication

The separate `sync-test-tenant-variables` job in Bicep Sync requires trusted
Tools `main` and manual dispatch with `enable_test_tenant_sync=true` (default
false). That input selects the publication operation, not which modules use
BAMI; only the central module groups select those paths. There is no global
activation variable. These execution controls also apply to planning.
`plan_only=true` is the default and never
writes variables; publication additionally requires `plan_only=false`.
The App must separately be approved for Actions Variables (`actions_variables: write`) on
`Azure/bicep-registry-modules`. Its variable token has no content, secret,
workflow, or pull-request write permission.
The pinned action's [generic permission-input parser](https://github.com/actions/create-github-app-token/blob/bcd2ba49218906704ab6c1aa796996da409d3eb1/lib/get-permissions-from-inputs.js)
maps `permission-actions-variables: write` to `actions_variables: write`.
Its manifest omits this input, so an undeclared-input warning can occur; the
runner still passes it to the action. Do not use `permission-variables` or omit
the explicit scope.

The existing CODEOWNERS job still runs on manual dispatch. Setting
`plan_only=false` also permits that job's existing merge behavior; review both
effects before dispatching. No workflow is enabled by changing the central
canary configuration alone. Scheduled Bicep Sync continues to run CODEOWNERS
only; it does not publish test-tenant variables. In contrast, selected Terraform
canaries attempt BAMI preparation during their normal sync, including scheduled
applies, subject to the candidate validation prerequisites.

[Invoke-BicepTestTenantSync.ps1](bicep-test-tenant-sync/scripts/Invoke-BicepTestTenantSync.ps1)
defaults to a read-only plan. Standalone publication requires an explicit,
operator-approved `-Apply`; `-PlanOnly:$false` is rejected, and `-Apply -WhatIf`
is write-free. The script uses the fixed central config and eight named
environment variables, plus `GH_TOKEN`; it accepts no target or config-path
override.

All eight values are required even for plans and deactivation. The publisher
checks snapshots around writes, verifies all five execution values, publishes
the module-path array last, and verifies the result. A nonempty existing array
freezes the execution values. Retargeting requires first publishing `[]` from
an all-legacy central selection; that deactivation changes only the array and
preserves the existing execution values. A subsequent inactive run can publish
the new bundle and desired selection.

Do not run other variable writers alongside the serialized workflow. GitHub
variables cannot be updated conditionally as one transaction: snapshot checks
detect observed edits but cannot eliminate races between reads and writes.
Failures never trigger write retries or rollback. Even a matching readback
after a lost response is reported as an error, so a failed run may already have
published the selector. Inspect the consumer before retrying. `Published`
means verified variable contents, not working Azure authentication.

## Terraform CODEOWNERS

Repository sync renders [CODEOWNERS.template](repository-sync/CODEOWNERS.template)
from [repository configuration](repository-config/config.json). Matching groups,
including the wildcard `default` group, contribute `codeOwnersTeams` for the
default `*` rule and `codeOwnersFileProtectionTeams` for the subsequent
`.github/CODEOWNERS` rule. Teams are deduplicated and qualified with the target
organization; a group targeting one repository can supply its specific owners.
An empty team list omits that configured rule.

The final rule is always
`metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners`, including when
configured team lists are empty. The unrooted basename covers root and child
metadata files; other files retain their configured owners. The teams are
alternatives: approval from either team satisfies code-owner review, not both.

Review enforcement also requires the existing active ruleset's
`require_code_owner_review = true` and visible teams with repository write
access. Default Terraform configuration grants both teams `push` without
adding environment approvals; the existing CODEOWNERS-file rule remains
engineering-only. Initial backfill uses only the existing AVM App's authorized
pull-request bypass. Neither the template nor its generation grants or broadens
that bypass; authorized operators must verify these prerequisites before rollout.

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
