# Create the 17 missing Terraform module repositories

- Status: complete
- Started: 2026-09-19
- Completed: 2026-09-19
- Branch: jaredfholgate-repo-creation-check

## Outcome

The catalog sync workflow flagged 17 Terraform modules whose repositories did not exist. All 17
were confirmed missing, then created, staged, published, and configured in the Microsoft open
source portal.

## Checklist

- [x] Confirm all 17 repositories were missing under both `terraform-azurerm-` and
      `terraform-azure-` naming.
- [x] Create each repository with `New-Repository.ps1`, using the `terraform-azure-` prefix.
- [x] Complete the open source portal wizard for each repository (Production, AVM service tree,
      `jaredholgate` plus `jatracey` as direct owners, `azure-verified-modules-module-owners`
      fallback, Sample code, MIT, telemetry yes, cryptography no, just-in-time elevation,
      both "Repository template" and "Add .gitignore" unchecked).
- [x] Elevate through just-in-time access and push the staged module content to each repository.
- [x] Tie each repository to the shared `service-AVM-azure-verified-modules-module-owners` rule,
      which also upgrades it to just-in-time v2.
- [x] Raise a single batch app-install pull request covering all 17 repositories
      (microsoft/github-operations#1837).

## Validation

- All 17 repositories return `visibility: public` with the full 17-file module scaffold present.
- Every repository reports the shared rule as attached successfully.

## Notes

The published project type in the wizard is **Sample code**, not "Product code". The public AVM
documentation should be corrected.

Repository descriptions and topics are still empty. Those are applied by repository sync once the
GitHub App install pull request is merged.
