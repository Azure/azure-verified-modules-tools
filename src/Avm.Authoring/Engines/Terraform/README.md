# Terraform engine

Terraform modules use native Terraform tooling: `terraform fmt`/`validate`,
TFLint, Conftest policies, terraform-docs, Mapotf transforms and
`terraform test`. These engine functions resolve pinned tools and run them for
the `avm` verbs; they do not wrap Terraform checks in Pester or PSRule.

`avm init -Ecosystem terraform` scaffolds or initialises a module repository.
`avm test` runs build validation only; `avm test unit`, `avm test integration`
and `avm test e2e` are the separate test tiers.
