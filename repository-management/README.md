# Repository management

This area owns the managed files, scheduled repository synchronization, and
operator-driven repository creation used by AVM Terraform repositories.

Repository sync and repository creation are intentionally independent.

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
`avm/res/network/front-door` selects `bami`.

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
[candidate state and activation prerequisites](repository-sync/README.md#bami-candidate-identities).

Bicep variable sync copies only the five execution fields: tenant, Bicep
client, subscription pool, management group, and persistent subscription.
It leaves all legacy values untouched. It derives `TEST_BAMI_MODULE_CONFIG`
from the central groups and publishes that metadata last:

```json
{"default":"legacy","modules":{"avm/res/network/front-door":"bami"}}
```

The [resolver action](test-tenant/actions/resolve-test-tenant/action.yml) must
be referenced at a reviewed literal commit SHA.

| Action contract | Value |
| --- | --- |
| `module-path` input | Canonical `avm/{res,ptn,utl}/{provider}/{module}`, or a safe descendant/test path |
| `module-config` input | `TEST_BAMI_MODULE_CONFIG`; absent means legacy |
| `bami-settings` input | JSON object containing the five execution variables |
| `test-tenant` output | Exactly `legacy` or `bami` |
| `settings-json` output | Complete normalized BAMI tuple, or `{}` for legacy |

The shared `Resolve-AvmTestTenant` helper in
[TestTenant.ps1](shared/TestTenant.ps1) takes `ModulePath`, `ModuleConfigJson`,
and `BamiSettingsJson`, returning `TestTenant` and `Settings`. Settings values
are strings, including the compact subscription-pool JSON. Invalid metadata or
an incomplete explicit BAMI tuple fails rather than falling back field by field.
Successful variable readback is not proof of Azure authentication or permissions.
Bicep activation also requires its own execution-identity federated credential
for the intended subject
`repository_owner_id:6844498:repository_id:447791597:environment:avm-validation`.
That credential and runtime login remain unproved; do not reuse the
Tools-controller credential or enable publication to work around this gate.

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
