# Azure Verified Modules — Tooling Report

A consolidated inventory of every tool, script, and automation used by the Azure Verified Modules (AVM) programme across the two flagship ecosystems:

- **Bicep**: [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules) (single monorepo).
- **Terraform**: [Azure/avm-terraform-governance](https://github.com/Azure/avm-terraform-governance) plus one repository per module under [github.com/Azure](https://github.com/Azure) (e.g. [terraform-azurerm-avm-res-keyvault-vault](https://github.com/Azure/terraform-azurerm-avm-res-keyvault-vault)).

The intent of this report is descriptive — what each tool is and what it does — and forms the basis for the consolidation plan in [avm-consolidation-plan.md](avm-consolidation-plan.md).

---

## 1. Executive Summary

**Bicep** is a single-repo, PowerShell-first ecosystem. Almost every check, generator, validator, publisher and governance bot is a PowerShell 7 script driven from `utilities/` and orchestrated by GitHub Actions composite actions under `.github/actions/templates/`. The only significant non-PowerShell dependencies are the Bicep CLI itself, Prettier/ESLint for JSON/YAML formatting, and PSRule.Rules.Azure for Azure best-practice analysis. There are roughly 30 first-party PowerShell scripts, 7 composite GitHub Actions, ~15 platform workflows, and 200+ per-module workflows generated from a single template.

**Terraform** is a multi-repo, Go-binary-first ecosystem. Each module lives in its own repo and pulls shared tooling at runtime from `Azure/avm-terraform-governance` (Makefile, porch configs, mapotf rules, grept policies, tflint configs). Execution is container-first via a `./avm` wrapper around `mcr.microsoft.com/azterraform:avm-latest`. Custom AVM logic is implemented as Go CLIs (`avmfix`, `porch`, `mapotf`, `grept`) — some maintained inside the Azure GitHub organisation, others on personal accounts (`lonegunmanb`, `matt-FFFFFF`). Native Terraform tooling (`terraform fmt`, `terraform validate`, `terraform test`) and third-party scanners (`tflint`, `terraform-docs`, `conftest`/OPA, `trivy`) are also bundled.

### Side-by-side contrast

| Dimension                | Bicep                                                                  | Terraform                                                                          |
| ------------------------ | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Repo topology            | Single monorepo                                                        | One repo per module + central governance repo                                      |
| Primary language         | PowerShell 7                                                           | Go (custom tools) + Bash/PowerShell (wrappers)                                     |
| Execution model          | Direct script invocation (`pwsh -File ...`)                            | Containerised via `./avm` wrapper                                                  |
| Orchestration            | GitHub Actions composite actions + PowerShell scripts                  | `porch` YAML pipelines + Makefile                                                  |
| Formatting               | `bicep format`, Prettier                                               | `terraform fmt`, `avmfix`                                                          |
| Linting                  | Bicep linter (`bicepconfig.json`), ESLint                              | `tflint` + AVM plugin                                                              |
| Unit testing             | Pester                                                                 | `terraform test` with mock providers                                               |
| Integration testing      | ARM what-if + actual deployment via `Test-ModuleLocally.ps1`           | `terraform test` against real Azure + example deployments via `test-examples.porch.yaml` |
| Static / compliance      | Giant Pester compliance suite + PSRule.Rules.Azure                     | `grept` HCL policies + Conftest/OPA (APRL, AVMSEC)                                 |
| Doc generation           | `Set-ModuleReadMe.ps1` (custom, from Bicep metadata)                   | `terraform-docs` between marker comments                                           |
| Publishing               | `bicep publish` → Public Bicep Registry (`br/public:`)                 | Terraform Registry via Git tags                                                    |
| Governance automation    | `Set-Avm*` PowerShell scripts driven by platform workflows             | `tf-repo-mgmt/` Terraform + PowerShell `New-Repository.ps1` + Azure Automation reaper |
| Distribution of shared assets | Everything in-repo                                                | Pulled at runtime from governance repo `main` branch                               |
| Supply chain ownership   | All under `Azure/*`                                                    | Mixed: `Azure/*`, `lonegunmanb/*`, `matt-FFFFFF/*`                                |

---

## 2. AVM Bicep Tooling

All paths are relative to [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules).

### 2.1 Local development

| Tool                | Type                 | Location              | Invocation                              | Local | CI  | AVM-specific | Purpose                                                       |
| ------------------- | -------------------- | --------------------- | --------------------------------------- | ----- | --- | ------------ | ------------------------------------------------------------- |
| Bicep CLI           | Go binary            | External (Microsoft)  | `bicep build/format/publish`            | Yes   | Yes | No           | Transpile Bicep to ARM, format, publish to registry           |
| Prettier            | npm package          | `package.json`        | `npm run prettier`                      | Yes   | Yes | No           | Format JSON / YAML / Markdown                                 |
| ESLint              | npm package          | `package.json`        | `npm run lint:fix`                      | Yes   | Yes | No           | Lint JSON / YAML / JS configuration files                     |
| `bicepconfig.json`  | JSON config          | Repo root             | Auto-loaded by Bicep CLI                | Yes   | Yes | Yes          | Bicep linter rules, severity, custom rules                    |
| `.editorconfig`     | Config               | Repo root             | Editor-driven                           | Yes   | n/a | No           | Indent, line-ending, charset                                  |

### 2.2 Core PowerShell orchestration (`utilities/tools/`)

| Tool                                | Type           | Local | CI  | Purpose                                                                                                |
| ----------------------------------- | -------------- | ----- | --- | ------------------------------------------------------------------------------------------------------ |
| `Set-AVMModule.ps1`                 | PS 7 script    | Yes   | Yes | Master orchestrator: builds Bicep → JSON, regenerates README, scaffolds tests, updates module layout   |
| `Test-ModuleLocally.ps1`            | PS 7 script    | Yes   | No  | Unified local: Pester unit tests, ARM validation, what-if, actual deployment, idempotency              |
| `Set-ChangelogEntryOnModules.ps1`   | PS 7 script    | No    | Yes | Append/refresh `CHANGELOG.md` per module on version changes                                            |
| `Export-StaticTestsAsOutput.ps1`    | PS 7 script    | No    | Yes | Convert Pester results into GitHub annotations + workflow summary                                      |
| `Invoke-WorkflowsForBranch.ps1`     | PS 7 script    | Yes   | Yes | Bulk-trigger GitHub Actions runs for many modules via the GitHub API with regex filters and inputs    |
| `Invoke-WorkflowsFailedJobsReRun.ps1` | PS 7 script  | Yes   | Yes | Re-run only the failed jobs from a workflow run                                                        |

Key parameters for `Set-AVMModule.ps1`: `-ModuleFolderPath`, `-Recurse`, `-SkipBuild`, `-SkipReadMe`, `-InvokeForDiff`.

### 2.3 Shared pipeline scripts (`utilities/pipelines/sharedScripts/`)

| Script                                          | Purpose                                                                                |
| ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| `Set-ModuleReadMe.ps1`                          | Generate the full module README from Bicep metadata, parameters, outputs, test files   |
| `Build-ViaRPC.ps1`                              | Invoke the Bicep CLI build path via its RPC interface with structured error handling   |
| `Get-CrossReferencedModuleList.ps1`             | Walk Bicep `module` statements to identify child / related modules                     |
| `Get-ModuleList.ps1`                            | Discover modules by scanning for `main.bicep`; filter by `res`/`ptn`/`utl` scope       |
| `Set-EnvironmentOnAgent.ps1`                    | Install required modules on CI runner (Az.*, PSRule, Pester, ImportExcel, etc.)        |
| `Connect-AzAccountWithGitHubOidc.ps1`           | Establish zero-secret Azure auth using a GitHub OIDC token                             |
| `Get-GitDiff.ps1`                               | Identify files changed vs `main`                                                       |
| `Get-PipelineFileName.ps1`                      | Map module folder → corresponding GitHub Actions workflow file                         |
| `Get-LocallyReferencedFileList.ps1`             | Find files referenced from a Bicep file (modules, imports) for token replacement       |
| `Get-NestedResourceList.ps1`                    | Parse child resources from Bicep                                                       |
| `Get-ParentFolderPathList.ps1`                  | Walk parent folders for module hierarchy resolution                                    |
| `Get-ScopeOfTemplateFile.ps1`                   | Determine deployment scope (`resourceGroup` / `subscription` / `managementGroup`)      |
| `Get-IsParameterRequired.ps1`                   | Determine required vs optional parameters for the README                               |
| `Invoke-AzStorageOperationWithOidicRetry.ps1`   | Storage operations with OIDC token refresh                                             |
| `Get-PublishedModuleVersionsList.ps1`           | Query the Bicep Public Registry for previously published versions                      |
| `ConvertTo-OrderedHashtable.ps1`                | Preserve key order in PowerShell hashtables for stable output                          |
| `tokenReplacement/Convert-TokensInFileList.ps1` | Replace `<namePrefix>`, `<resourceLocation>`, etc. in test parameter files             |

### 2.4 Composite GitHub Actions (`.github/actions/templates/`)

| Action                          | Purpose                                                                                  |
| ------------------------------- | ---------------------------------------------------------------------------------------- |
| `avm-setEnvironment`            | Set up the CI environment: dependencies, Azure SDK, workflow variables                   |
| `avm-getWorkflowInput`          | Parse workflow dispatch inputs into job outputs                                          |
| `avm-getModuleTestFiles`        | Discover module test files; honour `e2eIgnore` markers                                   |
| `avm-validateModulePester`      | Run Pester compliance + unit tests with token replacement                                |
| `avm-validateModulePSRule`      | Run PSRule.Rules.Azure against the module                                                |
| `avm-validateModuleDeployment`  | Run what-if and optional actual deployment, including region selection and cleanup       |
| `avm-publishModule`             | `bicep publish` validated module to the Public Bicep Registry                            |

### 2.5 Per-module and platform workflows (`.github/workflows/`)

**Per-module** workflows (~200+ files) are generated from a single template `avm.template.module.yml`:

| Pattern         | Purpose                                                              |
| --------------- | -------------------------------------------------------------------- |
| `avm.res.*.yml` | Resource module: validate + test + publish                           |
| `avm.ptn.*.yml` | Pattern module: validate + test + publish                            |
| `avm.utl.*.yml` | Utility module: validate + test + publish                            |

Typical job sequence: `avm-setEnvironment` → `avm-getWorkflowInput` → `avm-validateModulePester` → `avm-validateModulePSRule` → `avm-validateModuleDeployment` (what-if) → `avm-validateModuleDeployment` (deploy) → `avm-publishModule`.

**Platform** workflows (governance-wide):

| Workflow                                              | Purpose                                                  |
| ----------------------------------------------------- | -------------------------------------------------------- |
| `platform.check.psrule.yml`                           | PSRule across all modules; post results                  |
| `platform.ci-tests.yml`                               | Compliance test suite + unit tests                       |
| `platform.publish-tag.yml`                            | Publish a specific module version when a git tag is pushed |
| `platform.publish-module-index-json.yml`              | Update the AVM module index JSON                         |
| `platform.sync-avm-modules-list.yml`                  | Sync the module inventory                                |
| `platform.manage-workflow-issue.yml`                  | Open / close issues for failed workflows                 |
| `platform.set-avm-github-issue-owner-config.yml`      | Auto-assign issues to module owners                      |
| `platform.set-avm-github-pr-labels.yml`               | Auto-label PRs (needs core team, orphaned, …)            |
| `platform.on-pull-request-check-pr-title.yml`         | Enforce PR title format                                  |
| `platform.on-pull-request-check-labels.yml`           | Block merge based on labels                              |
| `platform.toggle-avm-workflows.yml`                   | Bulk enable / disable module workflows                   |
| `platform.deployment.history.cleanup.yml`             | Trim old deployment history                              |
| `platform.sync-repo-labels-from-csv.yml`              | Sync GitHub labels from the AVM CSV                      |
| `copilot-setup-steps.yml`                             | GitHub Copilot agent setup                               |

### 2.6 Testing frameworks

| Tool                       | Type             | Location                                                                            | Purpose                                                                  |
| -------------------------- | ---------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Pester                     | PS test runner   | `avm/**/tests/unit/`, `avm/**/tests/e2e/`, plus shared compliance file              | Unit tests, e2e Bicep tests, plus the shared 500-line compliance suite   |
| Compliance suite           | Pester file      | `utilities/pipelines/staticValidation/compliance/module.tests.ps1`                  | Validates file/folder layout, metadata, workflows, API versions, etc.    |
| PSRule.Rules.Azure         | PS module        | `microsoft/ps-rule@v2.9.0` action + `utilities/pipelines/staticValidation/psrule/`  | WAF-aligned best practices                                               |
| ARM what-if                | Az PowerShell    | `utilities/pipelines/e2eValidation/resourceDeployment/Test-TemplateDeployment.ps1`  | Dry-run deployment validation                                            |
| `Set-PesterGitHubOutput.ps1` | PS 7 script    | `utilities/pipelines/staticValidation/compliance/`                                  | Format Pester results as GitHub annotations + markdown summary           |

### 2.7 E2E deployment helpers (`utilities/pipelines/e2eValidation/`)

| Script                            | Purpose                                                                            |
| --------------------------------- | ---------------------------------------------------------------------------------- |
| `New-TemplateDeployment.ps1`      | Orchestrate ARM deployment with resource group lifecycle and cleanup               |
| `Test-TemplateDeployment.ps1`     | Validate ARM template + what-if; classify the diff                                 |
| `Get-AvailableResourceLocation.ps1` | Pick a region based on provider availability and quota                            |

### 2.8 Module publishing & registry (`utilities/pipelines/platform/`)

| Tool                                       | Purpose                                                                  |
| ------------------------------------------ | ------------------------------------------------------------------------ |
| `Invoke-AvmJsonModuleIndexGeneration.ps1`  | Build the AVM module index JSON consumed by AVM docs / GitHub Pages      |
| `Publish-ModuleFromTagToPBR.ps1`           | Run `bicep publish` against the Public Bicep Registry on a tag push      |
| `Get-AvmCsvData.ps1`                       | Query the AVM CSV index for module metadata (owner, status, version)     |

### 2.9 Governance automation (`utilities/pipelines/platform/`)

| Script                                  | Purpose                                                                                            |
| --------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `Set-AvmGitHubIssueForWorkflow.ps1`     | Open/close GitHub issues for failed workflows; notify module owners                                |
| `Set-AvmGitHubIssueOwnerConfig.ps1`     | Auto-assign issues to owners from the AVM CSV                                                      |
| `Set-AvmGitHubPrLabels.ps1`             | Label PRs (e.g. "needs core team" when sole owner is the author)                                   |
| `Switch-WorkflowState.ps1`              | Enable / disable workflows in bulk                                                                 |
| `Get-GitHubModuleWorkflowList.ps1`      | List module workflows in the repo                                                                  |
| `Get-GitHubModuleWorkflowLatestRun.ps1` | Get the latest workflow run for a branch                                                           |
| `Get-GitHubIssueList.ps1`               | Query GitHub issues                                                                                |
| `Get-GitHubIssueCommentsList.ps1`       | Retrieve issue comments                                                                            |
| `Get-GithubPrRequestedReviewerTeamNames.ps1` | Read requested reviewers from a PR                                                            |
| `Get-GithubTeamMembersLogin.ps1`        | Resolve members of a GitHub team                                                                   |

### 2.10 External services

| Service                                  | Role                                                                           |
| ---------------------------------------- | ------------------------------------------------------------------------------ |
| Public Bicep Registry (`br/public:`)     | Hosts published modules                                                        |
| Azure Resource Manager                   | What-if / deployment back end                                                  |
| Az PowerShell / Azure CLI                | Azure operations                                                               |
| GitHub REST/GraphQL API                  | Governance automation                                                          |
| `AzureAPICrawler` PS module              | Crawls Azure API versions for README + freshness checks                        |

---

## 3. AVM Terraform Tooling

All paths are relative to [Azure/avm-terraform-governance](https://github.com/Azure/avm-terraform-governance) unless otherwise noted.

### 3.1 Custom AVM Go binaries

| Tool             | Source repo                                                                                  | Maintainer    | Purpose                                                                                                       |
| ---------------- | -------------------------------------------------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------- |
| `avmfix`         | [lonegunmanb/avmfix](https://github.com/lonegunmanb/avmfix)                                  | lonegunmanb   | Auto-fix Terraform code to AVM standards (TFNFR8 argument order, TFNFR15 naming)                              |
| `porch`          | [matt-FFFFFF/porch](https://github.com/matt-FFFFFF/porch)                                    | matt-FFFFFF   | YAML-driven process orchestrator; runs pipeline steps with per-example pre/post hooks; TUI for local use      |
| `mapotf`         | [Azure/mapotf](https://github.com/Azure/mapotf)                                              | Azure         | "Modify A Piece Of Terraform" — HCL transformation engine driven by `.mptf.hcl` rules                         |
| `grept`          | [Azure/grept](https://github.com/Azure/grept)                                                | Azure         | Policy / convention engine for Terraform repos; rules in `.grept.hcl`                                          |
| `tfmod-scaffold` | [Azure/tfmod-scaffold](https://github.com/Azure/tfmod-scaffold)                              | Azure         | Template repository (not a runtime tool); source of Makefile, workflows, porch configs, managed-files          |

Container versions are pinned in `container/version.env` by git commit SHA.

#### `avmfix`

- CLI: `avmfix -folder <path>`.
- Runs in the pre-commit porch step.
- Also exposed as a GitHub Action at `.github/actions/avmfix/action.yml`.

#### `porch`

- CLI: `porch run [-f <config.yaml>] [--tui]`.
- Reads pipeline definitions from `porch-configs/*.porch.yaml`.
- Sources `.env` files from per-example directories.
- Honours `pre.sh` / `post.sh` / `pre.ps1` / `post.ps1` hooks per example.
- TUI mode for local development, non-TUI (`PORCH_NO_TUI=1`) for CI.

#### `mapotf`

- CLI: `mapotf transform --mptf-dir <dir> --tf-dir <dir>` followed by `mapotf clean-backup`.
- Active rules under `mapotf-configs/pre-commit/`:
  - `main_telemetry_tf.mptf.hcl` — add / update telemetry tracking resources.
  - `avm_headers_for_azapi.mptf.hcl` — inject AVM telemetry headers into AzAPI calls.
  - `required_provider_versions.mptf.hcl` — enforce provider version constraints.

#### `grept`

- CLI: `grept run`.
- Active rules under `grept-policies/`:
  - `outputs_tf.grept.hcl` — rename `output.tf` → `outputs.tf`.
  - `variables_tf.grept.hcl` — rename `variable.tf` → `variables.tf`.
  - `git_ignore.grept.hcl` — enforce `.gitignore` entries (`.terraform/`, `*.tfstate`, …).
  - `ensure_file_existence.grept.hcl` — require `terraform.tf`, `_header.md`.
  - `ensure_dir_existence.grept.hcl` — require `examples/`, `tests/` directories.
  - `deprecated_files.grept.hcl` — remove legacy workflow files and other deprecated artefacts.

### 3.2 Standard Terraform tooling

| Tool                | Type             | Where bundled                | Invocation                                | Local | CI  | AVM-specific             |
| ------------------- | ---------------- | ---------------------------- | ----------------------------------------- | ----- | --- | ------------------------ |
| `terraform fmt`     | HashiCorp binary | Container                    | `terraform fmt [-recursive]`              | Yes   | Yes | No                       |
| `terraform validate` | HashiCorp binary| Container                    | `terraform validate`                      | Yes   | Yes | No                       |
| `terraform test`    | Native runner    | Container                    | `terraform test` (1.6+)                   | Yes   | Yes | No (AVM-specific tests)  |
| `tflint`            | Go binary        | Container                    | `tflint -c <config>`                      | Yes   | Yes | No (AVM ruleset is)      |
| `terraform-docs`    | Go binary        | Container                    | `terraform-docs markdown <path>`          | Yes   | Yes | No                       |

`terraform test` test layout:

- `tests/unit/*.tftest.hcl` — unit tests with mock providers (`azapi`, `modtm`, `random`, `azurerm` where used). `command = apply` is safe because providers are mocked.
- `tests/integration/*.tftest.hcl` — real Azure infrastructure; uses ARM env vars / OIDC.
- Optional `tests/{unit,integration}/setup.sh` before `terraform init`.

### 3.3 TFLint + AVM ruleset

- Plugins: `terraform` v0.12.0, `avm` v0.16.0 (signed with the Azure key).
- Configs under `tflint-configs/`:
  - `avm.tflint.hcl` — root module rules.
  - `avm.tflint_module.hcl` — module-scope rules (stricter).
  - `avm.tflint_example.hcl` — examples (lenient).
  - Auto-generated merged config `avm.tflint.merged.hcl`.
  - Per-repo overrides via `.tflint.override*.hcl`.

### 3.4 Documentation generation

- `terraform-docs markdown <path> > README.md`, invoked from `make docs`.
- README blocks delimited by `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->`.

### 3.5 Security & compliance scanning

| Tool       | Type        | Role                                                                                            |
| ---------- | ----------- | ----------------------------------------------------------------------------------------------- |
| Conftest (OPA) | Go binary + Rego | Run AVM and APRL policies against `terraform plan` output                                 |
| Trivy      | Go binary   | CVE scan of container images / dependencies in the container build workflow                     |

Policy sets:

- **APRL** (Azure Proactive Resiliency Library):
  `git::https://github.com/Azure/policy-library-avm.git//policy/Azure-Proactive-Resiliency-Library-v2`
- **AVMSEC** (AVM Security):
  `git::https://github.com/Azure/policy-library-avm.git//policy/avmsec`
- Per-example exceptions: `examples/<name>/exceptions/*.rego`.

### 3.6 Supporting utilities

| Tool             | Source                                                                       | Role                                                                       |
| ---------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `tfpluginschema` | [matt-FFFFFF/tfpluginschema](https://github.com/matt-FFFFFF/tfpluginschema)  | Query Terraform / OpenTofu provider schemas (developer reference)          |
| `hcledit`        | Go binary                                                                    | CLI-based HCL block / attribute manipulation (internal container use)      |
| `hclmerge`       | Go binary                                                                    | Merge multiple HCL files; used to assemble the merged tflint config        |
| `azure-schema`   | Bash script under `.agents/skills/avm-terraform-module-development/scripts/` | Query [Azure/bicep-types-az](https://github.com/Azure/bicep-types-az) for Azure resource type schemas; 24h cache in `~/.cache/azure-schema/` |

### 3.7 Porch configurations (`porch-configs/`)

| File                          | Pipeline                                                                                       |
| ----------------------------- | ---------------------------------------------------------------------------------------------- |
| `pre-commit.porch.yaml`       | `avmfix` → `mapotf` → `grept` → `terraform fmt` / `validate` → `terraform-docs`                |
| `pr-check.porch.yaml`         | Pre-commit checks + `tflint` + Conftest                                                        |
| `test-examples.porch.yaml`    | Deploy each example to Azure with setup / teardown hooks; idempotency check via second `plan` |
| `terraform-test.porch.yaml`   | Run unit or integration tests (selected via `AVM_TEST_TYPE`)                                   |
| `global-setup.porch.yaml`     | Module-wide test fixture setup                                                                 |
| `global-teardown.porch.yaml`  | Module-wide test fixture teardown                                                              |

### 3.8 Makefile and `./avm` wrapper

The `Makefile` in module repos downloads `avmmakefile` from the governance `main` branch at runtime.

| Target               | Action                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------ |
| `make pre-commit`    | `porch run -f pre-commit.porch.yaml`                                                                         |
| `make pr-check`      | `porch run -f pr-check.porch.yaml`                                                                           |
| `make test-examples` | `porch run -f test-examples.porch.yaml`                                                                      |
| `make tf-test-unit`  | `porch run -f terraform-test.porch.yaml` (`AVM_TEST_TYPE=unit`)                                              |
| `make tf-test-integration` | `porch run -f terraform-test.porch.yaml` (`AVM_TEST_TYPE=integration`)                                 |
| `make globalsetup` / `globaltearown` | Module-wide fixture lifecycle                                                                  |
| `make docs`          | `terraform-docs` + header sync                                                                               |

The `./avm` shim (Bash + `./avm.ps1` for PowerShell):

- Validates Docker / Podman.
- Mounts `~/.azure`, custom SSL certificates, temp directories.
- Forwards `AVM_*`, `TF_VAR_*`, `ARM_*`, `GITHUB_TOKEN` into the container.
- Reads `avm.config.json` for per-repo overrides.
- Detects the GitHub Copilot Coding Agent (mkcert / `NODE_EXTRA_CA_CERTS`) for custom CA support.

### 3.9 Container image

| Aspect            | Detail                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------ |
| Registries        | `mcr.microsoft.com/azterraform:avm-latest`, `ghcr.io/azure/avm-terraform-governance:avm-latest`              |
| Build files       | `container/Dockerfile.build`, `container/Dockerfile.runtime`                                                 |
| Versioning        | `container/version.env` (git SHAs / semver per tool)                                                         |
| Bundled tooling   | Terraform, OpenTofu, `tflint`, `avmfix`, `porch`, `mapotf`, `grept`, Conftest, `terraform-docs`, `hcledit`, `hclmerge`, `tfpluginschema`, Azure CLI, `git`, `jq`, `curl`, `go-getter`, provider binaries (`azurerm`, `azapi`, `random`, `modtm`, …) |
| Scanning          | Trivy on each build                                                                                          |

### 3.10 GitHub Actions

| Workflow / action                              | Purpose                                                                              |
| ---------------------------------------------- | ------------------------------------------------------------------------------------ |
| `.github/workflows/managed-pr-check.yml`       | PR gate that runs `porch pr-check`                                                   |
| `.github/workflows/governance-test.yml`        | Test governance-repo changes against mock modules                                    |
| `.github/actions/avmfix/`                      | Composite action: verify that `avmfix` has been applied                              |

Approval-gated environments: `pr-check`, `integration-test`, `examples-test`, `no-approval` (for Copilot).

Mock modules used for testing governance changes: `terraform-azurerm-avm-res-mock`, `terraform-azure-avm-res-mock`.

### 3.11 Module testing

| Layer                 | Tooling                                | Notes                                                                                 |
| --------------------- | -------------------------------------- | ------------------------------------------------------------------------------------- |
| Unit                  | `terraform test` + mock providers      | `tests/unit/*.tftest.hcl`; safe `apply` against mocks                                 |
| Integration           | `terraform test` + real Azure          | `tests/integration/*.tftest.hcl`; ARM env vars / OIDC; auto-destroy after            |
| Example deployment    | Porch + `terraform apply`              | One full apply per example with pre/post hooks; idempotency check via second `plan`  |

### 3.12 Repository governance (`tf-repo-mgmt/`)

| Asset                                       | Purpose                                                                            |
| ------------------------------------------- | ---------------------------------------------------------------------------------- |
| Terraform configs in `tf-repo-mgmt/`        | Create new AVM module repos; sync managed files; configure branch protection, rulesets, custom properties; manage CODEOWNERS |
| `tf-repo-mgmt/scripts/New-Repository.ps1`   | PowerShell bootstrap for new module repos                                          |
| `tf-repo-mgmt/reaper/ReaperScript.ps1`      | Azure Automation runbook that reaps orphaned test resources using Azure Resource Graph + tag / age thresholds |

### 3.13 Developer reference assets

| Asset                                                                         | Purpose                                          |
| ----------------------------------------------------------------------------- | ------------------------------------------------ |
| `.agents/skills/avm-terraform-module-development/SKILL.md`                    | 8-step development workflow                      |
| `.agents/skills/avm-terraform-module-development/references/terraform-test.md`| Unit / integration test writing guide            |
| `.agents/skills/avm-terraform-module-development/references/tfpluginschema.md`| Provider schema query examples                   |
| `.agents/skills/avm-terraform-module-development/references/azure-schema.md`  | Azure resource schema lookup guide               |
| `.agents/skills/avm-terraform-module-development/scripts/azure-schema*`       | Executable schema query scripts                  |

### 3.14 Key environment variables

```bash
# Container & execution
CONTAINER_RUNTIME=docker                     # or podman
CONTAINER_IMAGE=mcr.microsoft.com/azterraform:avm-latest
CONTAINER_PULL_POLICY=always

# Shared assets
AVM_PORCH_BASE_URL=git::https://github.com/Azure/avm-terraform-governance//porch-configs
AVM_PORCH_REF=main
AVM_MAKEFILE_REF=main
AVM_TFLINT_CONFIG_URL=https://raw.githubusercontent.com/Azure/avm-terraform-governance/main/tflint-configs
AVM_MPTF_URL=git::https://github.com/Azure/avm-terraform-governance.git//mapotf-configs
AVM_GREPT_URL=git::https://github.com/Azure/avm-terraform-governance.git//grept-policies

# Policy
AVM_CONFTEST_APRL_URL=git::https://github.com/Azure/policy-library-avm.git//policy/Azure-Proactive-Resiliency-Library-v2
AVM_CONFTEST_AVMSEC_URL=git::https://github.com/Azure/policy-library-avm.git//policy/avmsec
AVM_CONFTEST_EXCEPTIONS_URL=https://raw.githubusercontent.com/Azure/policy-library-avm/main/policy/avmsec/avm_exceptions.rego.bak

# Execution control
PORCH_NO_TUI=1
AVM_EXAMPLE=<example_name>
AVM_TEST_TYPE=unit|integration

# Azure auth
ARM_CLIENT_ID
ARM_TENANT_ID
ARM_SUBSCRIPTION_ID
ARM_OIDC_REQUEST_TOKEN
ARM_OIDC_REQUEST_URL
ARM_USE_OIDC

# Certificates
AVM_SSL_CERT_FILE=<path_to_pem>
NODE_EXTRA_CA_CERTS
CAROOT
```

---

## 4. Cross-cutting comparison

| Concern              | Bicep                                                            | Terraform                                                                |
| -------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Formatting           | `bicep format`, Prettier                                         | `terraform fmt`, `avmfix`                                                |
| Linting              | Bicep linter (`bicepconfig.json`), ESLint                        | `tflint` + AVM plugin (multiple configs per scope)                       |
| Code transformation  | `Set-AVMModule.ps1` regenerates README + tests                   | `mapotf` patches HCL with rules                                          |
| Convention checks    | Pester compliance file (`module.tests.ps1`)                      | `grept` HCL policy engine                                                |
| Best-practice review | PSRule.Rules.Azure                                               | Conftest / OPA (APRL + AVMSEC)                                           |
| Unit testing         | Pester                                                           | `terraform test` (mock providers)                                        |
| Integration testing  | ARM what-if + actual deploy via PowerShell                       | `terraform test` against real Azure + example deployments via Porch      |
| Doc generation       | `Set-ModuleReadMe.ps1` (custom)                                  | `terraform-docs`                                                         |
| Publishing           | `bicep publish` to Public Bicep Registry                         | Terraform Registry via Git tag                                           |
| Module catalogue     | AVM module index JSON generated from CSV                         | Module index in the Terraform Registry / AVM site                        |
| Auth in CI           | GitHub OIDC → Azure                                              | GitHub OIDC → Azure                                                      |
| Governance bots      | `Set-Avm*` PowerShell scripts in platform workflows              | `tf-repo-mgmt` Terraform + `New-Repository.ps1` + Azure Automation reaper |
| Distribution         | All in monorepo                                                  | Pulled at runtime from governance `main`                                 |
| Local execution      | `pwsh` direct                                                    | `./avm` container wrapper                                                |

---

## 5. Key observations

1. **Two paradigms, one programme.** The Bicep and Terraform sides have evolved independently and have almost no shared tooling, despite producing modules that follow the same AVM specifications.
2. **PowerShell vs Go.** Bicep is PowerShell-first. Terraform is Go-binary-first. Any consolidation strategy has to bridge these without forcing one side to throw away years of work.
3. **Monorepo vs per-module repo.** Bicep's tooling assumes a single repo with a giant `utilities/` tree; Terraform's tooling assumes shared assets fetched at runtime from a separate governance repo. The "where does the tool live" answer is fundamentally different.
4. **Container-first vs script-first.** Terraform standardises on a single container so every contributor — and every CI run — uses identical binary versions. Bicep distributes individual scripts and lets the runner install dependencies.
5. **Supply chain spread.** Two of the four Terraform custom tools (`avmfix`, `porch`) live on personal GitHub accounts (`lonegunmanb`, `matt-FFFFFF`) rather than inside the `Azure/*` organisation. This is a noteworthy risk if those maintainers became unavailable.
6. **Runtime pinning is weak on the Terraform side.** Module repos pull governance assets (Makefile, porch configs, mapotf rules, grept policies, tflint configs) from `main` at execution time, so any breaking change in the governance repo immediately affects the entire fleet.
7. **Test depth is comparable but expressed differently.** Both ecosystems run unit, integration / what-if, and example / e2e tests, but the Bicep side is a single PowerShell entry point (`Test-ModuleLocally.ps1`) and the Terraform side is a Porch pipeline of containerised steps.
8. **Documentation is generated, not authored, in both.** READMEs are regenerated from source on every change — `Set-ModuleReadMe.ps1` for Bicep, `terraform-docs` for Terraform.
9. **Authentication is already unified.** Both sides use GitHub OIDC into Azure with no stored secrets. This is the one cross-cutting concern that does not need any consolidation work.
10. **Governance automation is similar but separate.** Both sides have bots that open / close issues for failed workflows, assign owners, label PRs, and reap resources — yet none of the logic is shared.

The consolidation plan in [avm-consolidation-plan.md](avm-consolidation-plan.md) builds on this report to propose a unified CLI surface that delegates to the existing tools first (facade) and selectively replaces them over time.
