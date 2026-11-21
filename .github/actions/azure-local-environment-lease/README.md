# Azure Local environment lease

This composite action coordinates BRM lifecycle work and module consumers through
one ETag-protected Blob record. It is a cooperative lock: Blob data-plane RBAC is
the authorization boundary, and participants that bypass the action are not
fenced.

The caller must provide the nonsecret lock configuration as:

```json
{
  "schemaVersion": 1,
  "storageAccountResourceId": "/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Storage/storageAccounts/<account>",
  "containerName": "<container>",
  "blobName": "avm-hci-<64-lowercase-hex-digest>",
  "fixtureResourceGroupId": "/subscriptions/<id>/resourceGroups/<group>"
}
```

The digest is lowercase SHA-256 over the lowercase canonical `D` subscription
GUID encoded as UTF-8. The action rejects a valid-looking blob name derived from
another subscription.

The storage account and container must survive fixture teardown. Every
participating identity needs Reader access to the control resource group and
Reader access to the named storage account, plus Blob Data Contributor access
only to the lock container. The action does not
create the account, container, or fixture. It rejects a storage account in the
control resource group and fails when preexisting lock storage is unavailable.
It requires a service-principal Azure CLI context; retained user contexts and
storage keys are not supported.

Consumers supply the current `avm-generation` from BRM's pinned live readiness
check. The action verifies the supplied generation against the control
resource-group tag and never substitutes static repository configuration for
readiness. Lifecycle initial prepare uses `mode: lifecycle`,
`allowUninitialized: true`, and an empty generation only after the action proves
the control resource group is absent. The same lifecycle owner may later
refresh the record after BRM has created and verified a new generation.

`cleanupConfirmed` is accepted only when the caller has performed and verified
its own ecosystem-specific cleanup. The action does not infer cleanup from a
test status, release a partially cleaned deployment, or inspect BRM deployment
history. A failed or uncertain release leaves the acquired record intact.

Recovery requires the exact recorded owner hash, exact generation, an explicit
inactive-owner attestation, and a nonempty reason. There is no time-based or
automatic takeover. Owner hashes are audit labels, not secrets or proof of
authorization.
