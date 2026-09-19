# Drop provider/latest segment from generated Terraform registry URLs

- **Status**: complete
- **Started**: 2026-09-19
- **Branch**: `jaredfholgate-drop-registry-provider-segment`

## Outcome

`New-AvmCatalogIdentity` in `repository-management/module-catalog/scripts/ModuleCatalog.ps1`
now builds Terraform registry references as
`https://registry.terraform.io/modules/Azure/<module-name>`, without the
trailing `/<provider>/latest` segment. Terraform's registry resolves the
shorter URL to the latest version for the correct provider, and it avoids
baking in a provider name that can go stale after a module rename.

## Background

Companion PR
[Azure/Azure-Verified-Modules#2944](https://github.com/Azure/Azure-Verified-Modules/pull/2944)
strips the same `/<provider>/latest` segment from the already-generated CSV
index files. This slice keeps the module-catalog tool consistent going
forward so it doesn't regenerate the longer form on the next sync.

## Checklist

- [x] Searched `repository-management/module-catalog` and shared `repository-management`
      Terraform assets for every `registry.terraform.io` module-URL construction
- [x] Updated the single generation site (`New-AvmCatalogIdentity`)
- [x] Confirmed the Terraform Registry API query in `ModuleCatalog.Collection.ps1`
      (`/v1/modules/Azure/<id>/<provider>`) is a separate, still-correct API call,
      not the display URL, and left it unchanged
- [x] Confirmed the versioned submodule reference override in `ModuleCatalog.ps1`
      (uses `currentVersion`, not `latest`) is unaffected and left unchanged
- [x] Confirmed `repository-management/repository-sync/terraform/modules/github/github.repository.tf`
      already emits the short form and needed no change
- [x] No test or fixture hard-coded the old `/<provider>/latest` string for this
      code path, so no test changes were required
- [x] `./build.ps1 pre-commit`

## Validation

`ModuleCatalog.Component.Tests.ps1`, `ModuleCatalog.Collection.Tests.ps1`, and
`ModuleCatalog.Configuration.Tests.ps1` all pass (172/172). `./build.ps1
pre-commit` succeeded with 0 errors (pre-existing warnings only, none new).
