# Repository creation: open source portal lockdown ordering

- Status: complete
- Started: 2026-09-19
- Completed: 2026-09-19
- Branch: jaredfholgate-repo-creation-check

## Outcome

`New-Repository.ps1` now survives the Azure organisation's new-repository lockdown. Previously the
script created the repository and immediately pushed, which always failed because the Azure org
forces brand new repositories private with no direct owners until the open source portal setup
wizard is completed and the creator elevates through just-in-time access.

## Checklist

- [x] Pause the run between `gh repo create` and the first push so the operator can complete the
      open source portal wizard and elevate with JIT (`-OnRepositoryCreated` callback on
      `New-AvmRepositoryContent`).
- [x] Print the portal answers the operator has to copy in, including the warning to uncheck
      "Repository template" and "Add .gitignore" so the staged module content is not overwritten.
- [x] Reparent the initial commit onto the placeholder commit the portal seeds, instead of force
      pushing (`Join-AvmRepositorySeededHistory`).
- [x] Push with the `gh` credential helper, because Git Credential Manager can surface a token
      without the `workflow` scope and GitHub then rejects any push that adds
      `.github/workflows` files (`Get-AvmRepositoryGitCredentialArgument` plus the
      `-UseGitHubCredential` switch on `Invoke-AvmRepositoryCreationProcess`).
- [x] Keep call-site argument lists semantic so the component test fixtures still resolve the
      operation name from the first argument.

## Validation

- `./build.ps1 pre-commit` — 826 passed, 0 failed, 1 skipped.
- Exercised end to end against `Azure/terraform-azure-avm-res-network-virtualrouter` and
  `Azure/terraform-azure-avm-res-operationsmanagement-solution`.

## Notes

The documented "migrate to just-in-time v2" step is redundant. Tying the shared
`service-AVM-azure-verified-modules-module-owners` rule to a new repository upgrades it to v2
automatically and needs no approval when the creator is already a direct owner.
