Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Actual,
        [string]$Description
    )

    if (-not $Actual) {
        throw "Expected $Description."
    }
}

function Get-ScriptAst {
    param(
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
        throw "PowerShell parse errors in $Path : $($parseErrors -join '; ')"
    }

    return $ast
}

function Get-FunctionAst {
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$Name
    )

    return $Ast.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        },
        $true
    )
}

function Get-CommandParameterNames {
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$Name
    )

    $command = $Ast.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq $Name
        },
        $true
    )
    Assert-True -Actual ($null -ne $command) -Description "a call to $Name"

    return @(
        $command.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
            ForEach-Object { $_.ParameterName }
    )
}

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$workflowPath = Join-Path (Join-Path (Join-Path $repoRoot ".github") "workflows") "repository-management-sync.yml"
$syncScriptPath = Join-Path $PSScriptRoot "Invoke-RepositorySync.ps1"
$avmPreCommitPath = Join-Path (Join-Path $PSScriptRoot "lib") "AvmPreCommit.ps1"
$teamsAndUsersPath = Join-Path (Join-Path $PSScriptRoot "lib") "TeamsAndUsers.ps1"

$workflow = Get-Content -LiteralPath $workflowPath -Raw
Assert-True `
    -Actual ($workflow -match '(?m)^      force_file_update:\r?\n        description: .+\r?\n        default: false\r?\n        type: boolean$') `
    -Description "force_file_update to be a false-by-default boolean workflow input"
Assert-True `
    -Actual ($workflow -match '(?ms)if\s*\(\$triggerType -eq "workflow_dispatch"\)\s*\{.*?\$forceFileUpdate = "\$\{\{ inputs\.force_file_update \}\}"\.ToLower\(\) -eq "true".*?\}') `
    -Description "force_file_update to be read only for workflow_dispatch"
Assert-True `
    -Actual ($workflow.Contains('-forceFileUpdate:$forceFileUpdate')) `
    -Description "the workflow to forward force_file_update"
Assert-True `
    -Actual ($workflow -notmatch 'force_user_removal|forceUserRemoval') `
    -Description "the removed force-user-removal workflow input and logic to stay absent"

$syncAst = Get-ScriptAst -Path $syncScriptPath
$syncParameterNames = @(
    $syncAst.ParamBlock.Parameters |
        ForEach-Object { $_.Name.VariablePath.UserPath }
)
Assert-True -Actual ($syncParameterNames -contains "forceFileUpdate") -Description "Invoke-RepositorySync.ps1 to expose forceFileUpdate"
Assert-True -Actual ($syncParameterNames -notcontains "forceUserRemoval") -Description "Invoke-RepositorySync.ps1 to omit forceUserRemoval"

$preCommitCallParameters = Get-CommandParameterNames `
    -Ast $syncAst `
    -Name "Invoke-AvmPreCommitForRepository"
Assert-True `
    -Actual ($preCommitCallParameters -contains "forceFileUpdate") `
    -Description "Invoke-RepositorySync.ps1 to forward forceFileUpdate"

$avmPreCommitAst = Get-ScriptAst -Path $avmPreCommitPath
$preCommitFunction = Get-FunctionAst `
    -Ast $avmPreCommitAst `
    -Name "Invoke-AvmPreCommitForRepository"
Assert-True -Actual ($null -ne $preCommitFunction) -Description "Invoke-AvmPreCommitForRepository to exist"
$preCommitParameterNames = @(
    $preCommitFunction.Body.ParamBlock.Parameters |
        ForEach-Object { $_.Name.VariablePath.UserPath }
)
Assert-True `
    -Actual ($preCommitParameterNames -contains "forceFileUpdate") `
    -Description "Invoke-AvmPreCommitForRepository to expose forceFileUpdate"

$decisionCallParameters = Get-CommandParameterNames `
    -Ast $preCommitFunction.Body `
    -Name "Resolve-AvmManagedFilesUpgradeDecision"
Assert-True `
    -Actual ($decisionCallParameters -contains "forceFileUpdate") `
    -Description "Invoke-AvmPreCommitForRepository to forward forceFileUpdate"

$teamsAndUsers = Get-Content -LiteralPath $teamsAndUsersPath -Raw
Assert-True `
    -Actual ($teamsAndUsers -notmatch 'forceUserRemoval') `
    -Description "the removed force-user-removal implementation to stay absent"

Write-Host "Repository sync input contract tests passed."
