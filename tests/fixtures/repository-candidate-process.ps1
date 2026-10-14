param(
    [string]$RepositoryRoot,
    [string]$CandidateDirectory,
    [string]$ReceiptDirectory,
    [string]$Scenario,
    [string]$Events,
    [ValidateSet('Validate', 'Publish')] [string]$Mode = 'Validate'
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $RepositoryRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
Import-Module $modulePath -Force
$env:AVM_CANDIDATE_PROCESS_SCENARIO = $Scenario
$env:AVM_CANDIDATE_PROCESS_EVENTS = $Events
& (Get-Module Avm.Authoring) {
    $script:candidateOriginalProcess = ${function:Invoke-AvmProcess}
    function script:Invoke-AvmProcess {
        [CmdletBinding()]
        param(
            [string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory,
            [int]$TimeoutSec, [switch]$IgnoreExitCode, [hashtable]$EnvVars,
            [switch]$StreamOutput, [scriptblock]$OnStdOutLine, [scriptblock]$OnStdErrLine
        )
        $name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        if ($name -eq 'gh' -or
            ($name -eq 'git' -and ($ArgumentList -contains 'push' -or
                    (($ArgumentList -contains 'clone' -or $ArgumentList -contains 'fetch' -or $ArgumentList -contains 'ls-remote') -and
                        @($ArgumentList | Where-Object { $_ -match '^(https?://|ssh://|git@)' -or $_ -eq 'origin' }).Count -gt 0))) -or
            ($ArgumentList -contains 'diff' -and $ArgumentList -contains '--binary')) {
            Add-Content -LiteralPath $env:AVM_CANDIDATE_PROCESS_EVENTS -Value 'forbidden publication operation'
            throw 'Network and publication operations are forbidden in this process fixture.'
        }
        & $script:candidateOriginalProcess @PSBoundParameters
    }
}
$fixtureBody = {
    function Invoke-AvmPrCheck {
        [CmdletBinding()]
        param([string]$Path, [string]$Ecosystem, [switch]$SkipModuleVersionCheck, [string[]]$ExcludeSteps)
        if ($ExcludeSteps.Count -ne 1 -or $ExcludeSteps[0] -cne 'check policy') {
            throw 'The repo-sync policy exclusion changed.'
        }
        Add-Content -LiteralPath $env:AVM_CANDIDATE_PROCESS_EVENTS -Value 'pr-check'
        switch ($env:AVM_CANDIDATE_PROCESS_SCENARIO) {
            throw { throw 'original thrown PR-check diagnostic' }
            missing { return $null }
            invalid { return [pscustomobject]@{ Error = 'original invalid PR-check diagnostic' } }
            default {
                $status = $env:AVM_CANDIDATE_PROCESS_SCENARIO
                [pscustomobject]@{
                    Status = $status
                    Steps = @([pscustomobject]@{
                            Step = 'transform'; Status = $status; Error = 'original returned PR-check diagnostic'
                        })
                }
            }
        }
    }
    function Invoke-AvmTestUnit {
        [CmdletBinding()]
        param([string]$Path, [string]$Ecosystem, [switch]$SkipModuleVersionCheck)
        Add-Content -LiteralPath $env:AVM_CANDIDATE_PROCESS_EVENTS -Value 'unit'
        [pscustomobject]@{ Status = 'pass' }
    }
    Export-ModuleMember -Function Invoke-AvmPrCheck, Invoke-AvmTestUnit
}
$fixtureDirectory = Join-Path (Split-Path $Events -Parent) 'fixture-module'
$null = New-Item -ItemType Directory -Path $fixtureDirectory -Force
[System.IO.File]::WriteAllText((Join-Path $fixtureDirectory 'fixture.psm1'), $fixtureBody.ToString())
$fixtureManifest = Join-Path $fixtureDirectory 'fixture.psd1'
[System.IO.File]::WriteAllText($fixtureManifest, "@{ ModuleVersion = '0.0.0'; RootModule = 'fixture.psm1' }")
Import-Module $fixtureManifest -Force
function Import-Module {
    [CmdletBinding()]
    param([string]$Name, [switch]$Force, [version]$RequiredVersion)
}
$entry = Join-Path $RepositoryRoot 'repository-management' 'repository-sync' 'scripts' 'Invoke-RepositoryCandidate.ps1'
$parameters = @{
    Repository = 'Azure/terraform-azurerm-avm-res-example'
    CandidateDirectory = $CandidateDirectory
    ReceiptDirectory = $ReceiptDirectory
}
& $entry -Mode $Mode @parameters
