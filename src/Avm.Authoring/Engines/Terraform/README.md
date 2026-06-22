# Terraform engine (Phase 1)

This folder is the entry point for the Terraform facade that wraps the
existing terraform-azure-verified-modules contributor workflows behind the
`avm` dispatcher.

Phase 1 will introduce these verbs (per `docs/avm-consolidation-plan.md`
section 6):

| Verb                                    | Public cmdlet                  | Status   |
| --------------------------------------- | ------------------------------ | -------- |
| `avm terraform test`                    | `Invoke-AvmTerraformTest`      | Pending  |
| `avm terraform publish`                 | `Publish-AvmTerraformModule`   | Pending  |
| `avm terraform scaffold`                | `New-AvmTerraformModule`       | Pending  |
| `avm terraform upgrade`                 | `Update-AvmTerraformModule`    | Pending  |

Until Phase 1 lands, this folder is intentionally empty apart from this
README. Phase 0 ships only the dispatcher, doctor, tool resolver, repo
classifier, and disable sentinel.
