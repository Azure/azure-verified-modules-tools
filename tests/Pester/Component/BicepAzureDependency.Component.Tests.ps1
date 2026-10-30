#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
    $script:manifest = Join-Path (Get-Module Avm.Authoring).ModuleBase 'Avm.Authoring.psd1'
    Import-Module -FullyQualifiedName @{ ModuleName = 'powershell-yaml'; RequiredVersion = '0.4.12' }
    $workflow = ConvertFrom-Yaml (Get-Content -Raw (Join-Path $PSScriptRoot '..' '..' '..' '.github' 'workflows' 'bicep-module-runtime-deployment.yml'))
    $context = $workflow.jobs.deploy.steps | Where-Object { $_['id'] -ceq 'context' }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($context.run, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'The runtime deployment context script is invalid.' }
    $script:provisioning = @($ast.EndBlock.Statements | Where-Object {
            $_.Extent.Text -match '^foreach\s*\(\$dependency\s+in\s+Get-AvmBicepAzureDependency\b'
        })[0].Extent.Text
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep cleanup dependency scope' -Tag Component {
    It 'provisions missing dependencies and verifies the guard in a fresh session' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $modules = Join-Path $root 'modules'
        $null = New-Item -ItemType Directory -Path $modules -Force
        $driver = Join-Path $root 'bootstrap.ps1'
        $provisioning = Join-Path $root 'provision.ps1'
        [IO.File]::WriteAllText($provisioning, $script:provisioning, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($driver, @'
param($Manifest, $Modules, $Mode, $Provisioning)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = $Modules + [IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
$env:AVM_OFFLINE = '0'
$module = Import-Module $Manifest -PassThru
& $module {
    function script:Get-AvmBicepAzureRequirement {
        [pscustomobject]@{ Name = 'Az.Accounts'; MinimumVersion = '5.3.4'; Commands = @{ 'Get-AzContext' = @() } }
        [pscustomobject]@{ Name = 'Az.Subscription'; MinimumVersion = '0.12.0'; Commands = @{ 'Disable-AzSubscription' = @('SubscriptionId') } }
    }
}
if ($Mode -eq 'install') {
        function Get-PSResourceRepository { param($Name) [pscustomobject]@{ Name = 'UserFeed'; Priority = 10 } }
        function Install-PSResource {
            [CmdletBinding()]
            param($Name, $Version, $Repository, $Scope, [switch]$TrustRepository, [switch]$Quiet)
            if ($Repository -cne 'UserFeed' -or $Scope -cne 'CurrentUser') { throw 'Incorrect installation scope.' }
            $command = if ($Name -ceq 'Az.Accounts') { 'Get-AzContext' } else { 'Disable-AzSubscription' }
            $directory = Join-Path $Modules $Name $Version
            $null = New-Item -ItemType Directory -Path $directory -Force
            New-ModuleManifest -Path (Join-Path $directory "$Name.psd1") -RootModule "$Name.psm1" `
                -ModuleVersion $Version -FunctionsToExport $command -CmdletsToExport @() -AliasesToExport @()
            $body = if ($Name -ceq 'Az.Accounts') {
                'function Get-AzContext { [CmdletBinding()] param() }'
            } else {
                'function Disable-AzSubscription { [CmdletBinding()] param([string] $SubscriptionId) }'
            }
            [IO.File]::WriteAllText((Join-Path $directory "$Name.psm1"), $body, [Text.UTF8Encoding]::new($false))
        }
        . $Provisioning
        if (Get-Module Az.Accounts, Az.Subscription) { throw 'Bootstrap imported an Azure module.' }
}
else {
    & $module { Assert-AvmBicepAzureDependency }
    'verified'
}
'@, [Text.UTF8Encoding]::new($false))
        InModuleScope Avm.Authoring -Parameters @{
            Driver = $driver; Manifest = $script:manifest; Modules = $modules; Root = $root; Provisioning = $provisioning
        } {
            param($Driver, $Manifest, $Modules, $Root, $Provisioning)
            $arguments = @('-NoProfile', '-NonInteractive', '-File', $Driver, '-Manifest', $Manifest, '-Modules', $Modules, '-Provisioning', $Provisioning)
            $missing = Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList ($arguments + @('-Mode', 'verify')) `
                -WorkingDirectory $Root -IgnoreExitCode
            $missing.ExitCode | Should -Not -Be 0
            $missing.StdErr | Should -Match 'Az.Subscription'
            $installed = Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList ($arguments + @('-Mode', 'install')) `
                -WorkingDirectory $Root
            $installed.ExitCode | Should -Be 0
            $verified = Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList ($arguments + @('-Mode', 'verify')) `
                -WorkingDirectory $Root
            $verified.StdOut | Should -Match 'verified'
        }
    }

    It 'keeps nested clients on the selected Accounts version with caller preload: <Preload>' -ForEach @(
        @{ Preload = $false }
        @{ Preload = $true }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $oldRoot = Join-Path $root 'older-first'
        $newRoot = Join-Path $root 'eligible-second'
        foreach ($item in @(
                @{ Root = $oldRoot; Name = 'Az.Accounts'; Version = '3.0.4'; Command = 'Get-AzContext' }
                @{ Root = $newRoot; Name = 'Az.Accounts'; Version = '5.3.4'; Command = 'Get-AzContext' }
                @{ Root = $newRoot; Name = 'Az.Resources'; Version = '9.0.3'; Command = 'Get-AzResource' }
            )) {
            $directory = Join-Path $item.Root $item.Name $item.Version
            $null = New-Item -ItemType Directory -Path $directory -Force
            New-ModuleManifest -Path (Join-Path $directory ($item.Name + '.psd1')) `
                -RootModule ($item.Name + '.psm1') -ModuleVersion $item.Version `
                -FunctionsToExport $item.Command -CmdletsToExport @() -AliasesToExport @()
            $body = "function $($item.Command) { [CmdletBinding()] param() throw [InvalidOperationException]::new('Unexpected Azure call.') }"
            if ($item.Name -eq 'Az.Resources') {
                $body = "Import-Module (Join-Path `$PSScriptRoot 'Client.psm1')`n" + $body
                [IO.File]::WriteAllText((Join-Path $directory 'Client.psm1'), @'
$accounts = Get-Module -Name Az.Accounts
if (-not $accounts) {
    $accounts = Import-Module Az.Accounts -MinimumVersion 2.7.5 -Scope Global -PassThru
}
if ($accounts.Version -ne [version]'5.3.4') {
    throw [InvalidOperationException]::new('A nested client autoloaded the legacy Accounts version.')
}
Export-ModuleMember -Function @()
'@, [Text.UTF8Encoding]::new($false))
            }
            [IO.File]::WriteAllText((Join-Path $directory ($item.Name + '.psm1')),
                $body, [Text.UTF8Encoding]::new($false))
        }
        $driver = Join-Path $root 'probe.ps1'
        [IO.File]::WriteAllText($driver, @'
param($Manifest, $OldRoot, $NewRoot, [switch]$Preload)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = @($OldRoot, $NewRoot, (Join-Path $PSHOME 'Modules')) -join [IO.Path]::PathSeparator
if ($Preload) {
    Import-Module (Join-Path $NewRoot 'Az.Accounts' '5.3.4' 'Az.Accounts.psd1') -Global
}
$module = Import-Module $Manifest -PassThru
& $module {
    function script:Get-AvmBicepAzureRequirement {
        [pscustomobject]@{
            Name = 'Az.Accounts'; MinimumVersion = '5.3.4'; Commands = @{ 'Get-AzContext' = @() }
        }
        [pscustomobject]@{
            Name = 'Az.Resources'; MinimumVersion = '9.0.3'; Commands = @{ 'Get-AzResource' = @() }
        }
    }
    Assert-AvmBicepAzureDependency
}
$accounts = Get-Module Az.Accounts
if ($null -eq $accounts -or $accounts.Version -ne [version]'5.3.4') {
    throw [InvalidOperationException]::new('The selected Accounts dependency is not globally visible.')
}
[pscustomobject]@{ AccountsVersion = $accounts.Version.ToString() } | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $driver,
            '-Manifest', $script:manifest, '-OldRoot', $oldRoot, '-NewRoot', $newRoot)
        if ($Preload) { $arguments += '-Preload' }
        InModuleScope Avm.Authoring -Parameters @{ Arguments = $arguments; Root = $root } {
            param($Arguments, $Root)
            $result = Invoke-AvmProcess -FilePath ([Environment]::ProcessPath) -ArgumentList $Arguments `
                -WorkingDirectory $Root -TimeoutSec 60
            ($result.StdOut | ConvertFrom-Json).AccountsVersion | Should -BeExactly '5.3.4'
        }
    }
}
