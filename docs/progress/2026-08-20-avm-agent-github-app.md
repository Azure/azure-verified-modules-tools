# Dedicated GitHub App for agentic code writes

**Status**: in-progress
**Started**: 2026-08-20
**Updated**: 2026-08-20
**Branch**: `myaschmitz-auto-fix-pr-agent`

## Outcome

Register a dedicated `avm-agent` GitHub App as the identity for agentic
workflows that write code, and keep it separate from the existing
`azure-verified-modules` App (ID `1049636`) used by repository sync.

Agentic code writes take untrusted input — an issue body authored by any outside
contributor. The sync App holds 31 permissions including `administration`,
`secrets`, and `workflows` write, and merges its own pull requests with
`gh pr merge --admin`, so it can bypass required checks. Reusing it would place
model-generated code inside that blast radius and behind that bypass.

Using a GitHub App rather than `GITHUB_TOKEN` is also what makes CI run at all:
GitHub suppresses workflow triggers from `GITHUB_TOKEN`, so a pull request it
opens arrives with zero checks. App installation tokens do not carry that
restriction.

## App specification

**Name**: `avm-agent` — surfaces as `avm-agent[bot]`.

**Repository permissions** (no organization or account permissions):

| Permission | Level | Why |
| --- | --- | --- |
| Contents | Read & write | Push the branch holding the change |
| Pull requests | Read & write | Open the pull request |
| Issues | Read & write | `protected-files` and `create-pull-request` issue fallbacks |
| Metadata | Read | Mandatory |

Grant nothing else. Omitting `workflows` structurally prevents enabling
gh-aw's `allow-workflows`, so `.github/workflows/` can never be written even by
a misconfigured workflow. Omitting `administration` means the App cannot merge
with `--admin` and cannot alter branch protection; it also disables gh-aw's
branch-protection pre-flight, so set `check-branch-protection: false` where
`push-to-pull-request-branch` is used to avoid a warning on every run.

**Subscribed events**: none. The App is a credential, not a listener.

**Installation**: selected repositories, not all. Installation membership is the
rollout gate — a workflow synced to a repository outside the installation cannot
mint a token and fails closed. This is enforced by GitHub, unlike managed-file
ring membership, which only controls which repositories receive the file.

**Credentials**: `AVM_AGENT_APP_CLIENT_ID` (organization variable) and
`AVM_AGENT_APP_PRIVATE_KEY` (organization secret), scoped to repositories in the
installation. Do not reuse `AVM_APP_CLIENT_ID` / `AVM_APP_PRIVATE_KEY`.

## Workflow wiring

```yaml
safe-outputs:
  github-app:
    client-id: ${{ vars.AVM_AGENT_APP_CLIENT_ID }}
    private-key: ${{ secrets.AVM_AGENT_APP_PRIVATE_KEY }}
    owner: Azure
  create-pull-request:
    draft: true
    signed-commits: true
    labels: [agentic-workflows]
    expires: 14d
    protected-files:
      policy: fallback-to-issue
      exclude:
        - README.md
```

`README.md` must be excluded from the protected set. gh-aw protects it by
default, but in an AVM module it is generated — `avm docs` regenerates it from
`_header.md`, `_footer.md`, and terraform-docs — so any change to a variable
description regenerates it and would otherwise be refused on every run.

The remaining gh-aw defaults are kept deliberately: `AGENTS.md`,
`CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `.github/`, and all
top-level dot-directories are protected, which is close to the managed-file set
and enforces "the agent does not edit managed files" without a bespoke guard.

Use a distinct branch prefix (`avm-agent/`) so pull-request-triggered automation
can exclude agent branches. Agent pull requests now trigger CI, which reopens the
event-cascade risk that `GITHUB_TOKEN` suppression exists to prevent.

## Checklist

- [ ] Register the App with the permission set above and no event subscriptions.
- [ ] Install on ring-0 (`terraform-azurerm-avm-ptn-example-repo`) only.
- [ ] Store the client ID and private key under the new names.
- [ ] Confirm a test pull request is authored by `avm-agent[bot]`, is draft, has
      verified commits, and triggers `pr-check`.
- [ ] Confirm a patch touching `.github/` or `AGENTS.md` is refused, and that a
      patch regenerating `README.md` is not.
- [ ] Confirm the App cannot merge its own pull request.
- [ ] Extend the installation to ring-1 once ring-0 is clean.

## Blockers or dependencies

- Registration and installation require Azure organization owner rights.
- `repository_selection` for the existing `azure-verified-modules` App is
  unverified; reading it needs `admin:org`. If it is `all`, the separation
  argument strengthens but nothing in this spec changes.
- Depends on nothing in the fixer workflow itself; the App can be registered and
  validated independently.
