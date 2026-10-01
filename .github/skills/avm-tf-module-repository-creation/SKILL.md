---
name: avm-tf-module-repository-creation
description: Use when asked to create, set up, or finish setting up a new Azure Verified Modules (AVM) Terraform module repository in the Azure GitHub organization, or to resume or troubleshoot repository setup with `avm init -Ecosystem terraform`. Covers the inputs to ask the user for, the Open Source Portal and just-in-time (JIT) steps, verification, recovery, and the final step of leaving jaredholgate and jatracey as the only Direct Owners. Trigger on "create a Terraform module repository", "new AVM module repo", "avm init terraform", "terraform-azure-avm-", "module proposal approved", "app installation request", "JIT tie", and "Direct Owners".
---

# Create an AVM Terraform Module Repository

`avm init -Ecosystem terraform` from the `Avm.Authoring` PowerShell module creates and sets up the repository. Each stage checks GitHub and the local folder first, so running the same command again continues an interrupted setup. Your job is to collect approved inputs, run the command, relay the manual steps to the user, and verify the result.

The operator guide is <https://azure.github.io/Azure-Verified-Modules/contributing/terraform/repository-setup/>, and each stage is described in [the Avm.Authoring README](https://github.com/Azure/azure-verified-modules-tools/blob/main/src/Avm.Authoring/README.md#initialize-a-terraform-module-repository).

## Rules

- This changes production systems: a public repository in the `Azure` organization, team access, a push to `main`, a pull request in `microsoft/github-operations`, and Open Source Portal settings. Get the user's explicit approval before the first run without `-WhatIf`, and again before you change anything in the portal for them.
- Let `avm init` make every GitHub change. Do not push to `main`, change the `global-rulesets-opt-out` custom property, grant team access, or open the app installation pull request yourself. Never edit or delete the records in the `repository-init` folder of the Avm state directory.
- Use only approved values from the module proposal, confirmed by the user. Never infer `canonicalType` from the module name, and never choose a `telemetryIdPrefix`; `avm init` mints one.
- The setup is not complete until `jaredholgate` and `jatracey` are the only individual Direct Owners in the Open Source Portal. This is always the last step ([step 7](#7-last-step-leave-only-jaredholgate-and-jatracey-as-direct-owners)), done once everything else is finished.
- Ask the user one question at a time, and offer the values you found as choices.

## 1. Check the prerequisites

Run these read-only checks and resolve any gaps first:

```pwsh
$PSVersionTable.PSVersion   # 7.4 or later
git --version
git config --global user.name
git config --global user.email
gh auth status --hostname github.com
```

- `gh` must be signed in to github.com with the `repo`, `read:org` (or `write:org` or `admin:org`), and `workflow` scopes. If any are missing, ask the user to run `gh auth refresh --hostname github.com --scopes read:org,workflow`. It opens a browser, so the user must run it.
- If `GH_TOKEN` or `GITHUB_TOKEN` is set, `gh` and `avm init` use that token instead of the signed-in account, and agent environments often set one without these scopes. When `gh auth status` shows that the token lacks the scopes but the user's signed-in account has them, clear both in the PowerShell session that runs `avm init`:

  ```pwsh
  $env:GH_TOKEN = $null
  $env:GITHUB_TOKEN = $null
  ```

- Install or update the module, then import it:

  ```pwsh
  Install-PSResource -Name Avm.Authoring -Repository PSGallery -TrustRepository
  Import-Module Avm.Authoring
  ```

  Run `avm update` instead when an older release is already installed.
- The user needs AVM core team approval to create the repository, a GitHub account linked in the [Open Source Portal](https://repos.opensource.microsoft.com/link), and membership of the `Azure` organization. They also need to be able to fork `microsoft/github-operations`, because the app installation pull request is opened from their fork.

## 2. Collect the inputs

Find the approved module proposal with `gh search issues --repo Azure/Azure-Verified-Modules "<module name>"`, or ask the user for the issue number, and read it with `gh issue view <number> --repo Azure/Azure-Verified-Modules`. The proposal form gives the module name, its classification, the resource type under **Module Details**, and the owner handles. Confirm with the user that the proposal is approved before continuing.

Ask the user for each value, offering what you found:

| Input | Rule | Example |
| --- | --- | --- |
| Module name | `avm-<type>-<name>`, where `<type>` is `res`, `ptn`, or `utl`; lowercase with hyphens | `avm-res-signalrservice-webpubsub` |
| Repository name | `terraform-azure-` followed by the module name | `terraform-azure-avm-res-signalrservice-webpubsub` |
| Module type | `resource`, `pattern`, or `utility`, matching `res`, `ptn`, or `utl` | `resource` |
| Display name (`moduleDisplayName`) | The approved display name | `SignalR Service Web PubSub` |
| Description (`moduleDescription`) | The approved one-sentence description | `AVM Terraform resource module for SignalR Service Web PubSub.` |
| Canonical type (`canonicalType`) | The ARM resource type for a resource module, or the approved taxonomy for a pattern or utility module | `Microsoft.SignalRService/webPubSub` |
| Owners (`owners`) | Approved GitHub handles or `@Azure/<team>` entries | `sujaypillai` |
| Telemetry ID prefix (`telemetryIdPrefix`) | Only when the proposal assigned one; otherwise leave it out | |
| Alternative names (`alternativeNames`) | Optional | |
| Parent folder | An existing folder for the local clone | `C:\code` |

The values become `metadata.json` in the first commit, and the display name and description start the module's `_header.md` and README.

## 3. Preview the run and get approval

If your shell cannot answer prompts, `avm init` cannot ask for missing values, so pass them all with `-InputObject`. The local folder's name must be the repository name. Preview first:

```pwsh
$metadata = @{
    moduleDisplayName = '<display name>'
    moduleDescription = '<description>'
    canonicalType     = '<canonical type>'
    owners            = @('<owner>')
}
$path = Join-Path '<parent folder>' '<repository name>'
avm init -Ecosystem terraform -ModuleType resource -Path $path -InputObject $metadata -WhatIf
```

Expect `planned` steps for `metadata` and `repository` when the repository does not exist yet. Show the user the repository URL and the values, and ask for approval to create the repository.

## 4. Run avm init and relay the manual steps

Run the same command without `-WhatIf`. When a stage needs the user, the run stops and prints instructions. `avm` then lists the steps and throws `avm init reported Status 'fail'`, so wrap the call in `try`/`catch` and read the failed step. Relay it to the user, and run the same command again once they confirm. Later runs read the values from the local `metadata.json` and ignore `-InputObject`.

A new repository normally takes two runs:

1. **The first run** writes `metadata.json`, creates the repository, and stops at `open source portal setup`. Give the user the portal link and the answers it printed. The guide also asks them to add themselves, `jaredholgate`, and `jatracey` as Direct Owners, with `azure-verified-modules-module-owners` as the fallback security group. They need to be a Direct Owner until the setup is finished, and [step 7](#7-last-step-leave-only-jaredholgate-and-jatracey-as-direct-owners) removes them. They uncheck **Repository template** and **Add .gitignore**, finish the setup, then select **Elevate your access**. Wait for the user to confirm.
1. **The second run** grants the contributors and readers teams, publishes the first commit, opens the app installation pull request, clones the repository, and ends with two `manual` portal steps: the JIT tie, then the Direct Owners check. If it stops at `administrator access` instead, ask the user to select **Elevate your access** on the repository's portal page.

Elevation can take a minute to reach GitHub. Before running again, poll until GitHub shows the repository as public and the user as an administrator:

```pwsh
gh api 'repos/Azure/<repository name>' --jq '"visibility=\(.visibility) admin=\(.permissions.admin)"'
```

The first commit runs `avm pre-commit`, which downloads Terraform and other tools on first use, so allow a few minutes.

## 5. Tie the repository to the shared JIT rule

The Open Source Portal offers no API that `avm init` could use to check this, so every completed run lists it as `manual`. Do it after the second run, because it changes how elevation works.

1. Open `https://repos.opensource.microsoft.com/orgs/Azure/repos/<repository name>`.
1. Select **Advanced JIT options**, then **Propose a new tie**.
1. Enter the rule ID `service-AVM-azure-verified-modules-module-owners`, then select **Review** and **Create tie**.

The result page says whether the tie is active or waiting for an owner of the rule to approve it. On a JIT v1 repository, a tie proposed by a Direct Owner can become active at once. Once active, the repository overview shows **JIT version: JIT v2** and the rule. A user who does not have permission skips this step and emails avm@microsoft.com with the repository name.

Ask the user to do this. Only with their explicit approval, do it for them through browser automation in their signed-in browser.

## 6. Verify the setup

Run these read-only checks:

```pwsh
$repo = 'Azure/<repository name>'
gh api "repos/$repo/commits?per_page=3" --jq '.[].commit.message'
gh api "repos/$repo/properties/values" --jq '.[] | "\(.property_name)=\(.value)"'
foreach ($team in 'azure-verified-modules-module-contributors', 'azure-verified-modules-module-readers') {
    gh api -H 'Accept: application/vnd.github.v3.repository+json' "orgs/Azure/teams/$team/repos/$repo" --jq '.permissions'
}
git -C $path status --short
```

- `main` holds `chore: initialize module repository` on top of the portal's README commit.
- `global-rulesets-opt-out` is back to its original value, normally `false`.
- The contributors team has push access and the readers team has triage access.
- The local clone is clean, and `_header.md` starts with the display name and description.

Running `avm init` again should change nothing. Every step passes except `app installation`, which stays `pending` until the request is approved, and the two `manual` portal steps.

## 7. Last step: leave only jaredholgate and jatracey as Direct Owners

Do this last, once everything else is done: `avm init` has completed, the JIT tie is in place, and the checks above pass. The app installation request can still be awaiting approval, because it does not need Direct Owner access. After this step, `jaredholgate` and `jatracey` must be the only individual Direct Owners. Remove everyone else, including the user and whoever created the repository, and keep the `azure-verified-modules-module-owners` fallback security group.

Changing owners is an access change, so ask the user to do it, or get their explicit approval before doing it for them through browser automation:

1. Elevate to administrator. On the repository's **Just-in-time Access** tab, select **Next**, enter a justification, and select the button that elevates the user's GitHub login to Administrator. Wait until `admin=true` (see step 4).
1. On the repository overview, select **Change owners** under **Direct Owners**. The button only appears while elevated, and the **Compliance** tab does not show the editor.
1. Remove every individual owner other than `jaredholgate` and `jatracey`. The first two owner slots are required, and **Save** stays disabled while either is empty. If removing someone empties a required slot, remove `jaredholgate` or `jatracey` from a later slot and search for them in the empty required slot instead.
1. Keep the fallback security group, then select **Save**.
1. Reload the overview and check that **Individual Direct Owners** lists only Jack Tracey and Jared Holgate.

A user who cannot change the owners emails avm@microsoft.com with the repository name.

## Report to the user

- the repository URL;
- the app installation pull request link. The `microsoft/github-operations` maintainers approve it, and repository sync then applies the shared configuration and managed files;
- whether the JIT tie is active or still pending;
- whether `jaredholgate` and `jatracey` are now the only individual Direct Owners; and
- the local clone path.

## Recovery

Run the same command again from the same machine after fixing the cause.

| Message | What to do |
| --- | --- |
| `The GitHub CLI is not signed in to github.com` | Ask the user to run `gh auth login --hostname github.com --web --git-protocol https --scopes workflow`. |
| `The GitHub CLI token is missing the ... scope(s)` | Ask the user to run the printed `gh auth refresh` command, or clear `GH_TOKEN` and `GITHUB_TOKEN`. |
| `Configure a Git commit identity` | Ask the user for the name and email to set with `git config --global user.name` and `git config --global user.email`. |
| `Missing required metadata fields` | Add the missing values to `-InputObject`. |
| `The -Path folder name must be the repository name` or `is not an AVM Terraform repository name` | Use `<parent folder>/<repository name>` with a valid repository name. |
| `Complete the open source portal setup` | Relay the portal steps, as for the first run. |
| `Elevate your access to ... with JIT` | Ask the user to elevate, wait until `admin=true`, then run again. |
| `avm pre-commit failed` | Read the issues in that step's result, fix the cause (often a failed tool download), then run again. |
| `Could not restore global-rulesets-opt-out` or `has not been restored` | Run again on the same machine; it restores the recorded value. |
| `global-rulesets-opt-out is true, but ... no record` or `global-rulesets-opt-out is already true` | Stop and tell the user. If `avm init` was interrupted on another machine, run it there. Otherwise a repository administrator sets the property back to its original value, normally `false`. |
| `Repository sync already protects main`, `main already contains files without metadata.json`, `main has metadata.json but is missing`, or `metadata.json on main is invalid` | The repository needs its files through a pull request. Tell the user; do not push to `main`. |
| `local clone` is `skipped` | The folder holds other files, which `avm init` never overwrites. Ask the user where to clone instead. |
