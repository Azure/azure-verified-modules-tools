#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepositoryRoot,
    [Parameter(Mandatory)] [version] $PesterVersion,
    [AllowEmptyString()] [string] $Fixture = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $RepositoryRoot 'build' 'AvmPesterSharding.ps1')
Initialize-AvmPesterRegistryRoot
Import-Module Pester -RequiredVersion $PesterVersion -Force
[Environment]::SetEnvironmentVariable('AVM_INTEGRATION_FIXTURE',
    $(if ($Fixture) { $Fixture } else { [NullString]::Value }), 'Process')
$configuration = New-PesterConfiguration
$configuration.Run.Path = @(Get-AvmIntegrationTestFile `
    -Path (Join-Path $RepositoryRoot 'tests' 'Pester' 'Integration') -Group Terraform)
$configuration.Run.SkipRun = $true
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$discovery = Invoke-Pester -Configuration $configuration
if ($discovery.FailedCount -gt 0) { throw 'Integration discovery failed.' }
$blocks = [Collections.Generic.Queue[object]]::new()
foreach ($container in $discovery.Containers) {
    foreach ($block in $container.Blocks) { $blocks.Enqueue($block) }
}
$tests = @(
    while ($blocks.Count -gt 0) {
        $block = $blocks.Dequeue()
        foreach ($test in $block.Tests) {
            $identity = [ordered]@{}
            foreach ($scope in @('Test', 'Context')) {
                $data = if ($scope -ceq 'Test') { $test.Data } else { $block.Data }
                $ordered = [ordered]@{}
                if ($data -is [Collections.IDictionary]) {
                    foreach ($name in @($data.Keys | Sort-Object -CaseSensitive)) { $ordered[$name] = $data[$name] }
                }
                $identity[$scope] = $ordered
            }
            ($test.Path -join '.') + ':' + (ConvertTo-Json -InputObject $identity -Compress -Depth 10)
        }
        foreach ($child in $block.Blocks) { $blocks.Enqueue($child) }
    }
)
ConvertTo-Json -InputObject $tests -Compress
