#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-AvmWorkflowPackagePrivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [hashtable] $Parameters
    )

    $module = Get-Module -Name Avm.Authoring | Select-Object -First 1
    if ($null -eq $module) {
        Import-AvmWorkflowPackage
        $module = Get-Module -Name Avm.Authoring | Select-Object -First 1
    }
    if ($null -eq $module) {
        throw [InvalidOperationException]::new('The installed Avm.Authoring package could not be imported for a Bicep workflow compatibility adapter.')
    }
    return & $module { param($CommandName, $CommandParameters) & $CommandName @CommandParameters } $Name $Parameters
}

function Resolve-AvmWorkflowPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath,
        [switch] $AllowMissing
    )

    $relative = $RelativePath.Replace('\', '/')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '[:\x00-\x1f*?\[\]]' -or
        $relative.Split('/') -contains '..' -or [string]::IsNullOrWhiteSpace($relative)) {
        throw [ArgumentException]::new('A workflow path must be a literal, repository-relative path without parent segments.')
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $relative))
    $prefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw [ArgumentException]::new('The workflow path must remain inside its checkout.')
    }
    $current = $rootPath
    foreach ($segment in $relative.Split('/', [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [ArgumentException]::new('Workflow inputs must not traverse linked files or directories.')
            }
        }
    }
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $path)) {
        throw [IO.FileNotFoundException]::new("Workflow input does not exist: $relative")
    }
    return $path
}

function ConvertFrom-AvmWorkflowScalarInput {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Json)

    try {
        $values = [System.Text.Json.JsonSerializer]::Deserialize[
            System.Collections.Generic.Dictionary[string, System.Text.Json.JsonElement]]($Json)
    }
    catch [System.Text.Json.JsonException] {
        throw [ArgumentException]::new('Workflow inputs must be a JSON object containing scalar values.', $_.Exception)
    }
    if ($null -eq $values) {
        throw [ArgumentException]::new('Workflow inputs must be a JSON object containing scalar values.')
    }
    $result = [ordered]@{}
    foreach ($entry in $values.GetEnumerator()) {
        $result[$entry.Key] = switch ($entry.Value.ValueKind) {
            String { $entry.Value.GetString() }
            Number { $entry.Value.GetRawText() }
            True { $true }
            False { $false }
            Null { $null }
            default { throw [ArgumentException]::new('Workflow input values must be strings, numbers, booleans or null.') }
        }
    }
    return $result
}

function ConvertTo-AvmWorkflowBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [object] $Value,
        [switch] $AllowEmpty
    )

    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string] -and $Value -match '^(true|false)$') { return $Value -ieq 'true' }
    if ($AllowEmpty -and ($null -eq $Value -or $Value -ceq '')) { return $false }
    throw [ArgumentException]::new('A workflow boolean must be true or false.')
}

function Write-AvmWorkflowOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [AllowEmptyString()] [string] $Value,
        [string] $FilePath = $env:GITHUB_OUTPUT
    )

    if ($Name -cnotmatch '^[A-Za-z][A-Za-z0-9_-]*$' -or $Value -match '[\r\n]') {
        throw [ArgumentException]::new('Workflow outputs require a safe name and a single-line value.')
    }
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        throw [InvalidOperationException]::new('The GitHub output file is not configured.')
    }
    [IO.File]::AppendAllText($FilePath, "$Name=$Value`n", [Text.UTF8Encoding]::new($false))
}

function Install-AvmWorkflowModule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [version] $Version,
        [switch] $Minimum
    )

    $hasVersion = $PSBoundParameters.ContainsKey('Version')
    if ($Minimum -and -not $hasVersion) {
        throw [ArgumentException]::new('A minimum workflow dependency version requires an explicit version.')
    }

    $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object {
            -not $hasVersion -or ($Minimum -and $_.Version -ge $Version) -or $_.Version -eq $Version
        } | Sort-Object Version -Descending)
    if ($hasVersion -and $installed.Count -gt 0) { return $installed[0] }
    $target = if ($hasVersion) { "$Name $Version" } else { "$Name latest stable" }
    if (-not $PSCmdlet.ShouldProcess($target, 'Install workflow dependency from configured PowerShell repositories')) { return }
    Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    $repositories = @(Get-PSResourceRepository -ErrorAction Stop | Sort-Object Priority, Name)
    if ($repositories.Count -eq 0) {
        throw [InvalidOperationException]::new('No PowerShell repositories are configured.')
    }
    foreach ($repository in $repositories) {
        try {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object {
                        -not $hasVersion -or ($Minimum -and $_.Version -ge $Version) -or $_.Version -eq $Version
                    } | Sort-Object Version -Descending)
                if ($hasVersion -and $installed.Count -gt 0) { return $installed[0] }
                $target = if ($hasVersion) { "$Name $Version" } else { "$Name latest stable" }
                try {
                    $parameters = @{
                        Name            = $Name
                        Repository      = $repository.Name
                        Scope           = 'CurrentUser'
                        TrustRepository = $true
                        Quiet           = $true
                        ErrorAction     = 'Stop'
                    }
                    if ($hasVersion) { $parameters['Version'] = $Version.ToString() }
                    Install-PSResource @parameters
                    $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object {
                            -not $hasVersion -or ($Minimum -and $_.Version -ge $Version) -or $_.Version -eq $Version
                        } | Sort-Object Version -Descending)
                    if ($installed.Count -gt 0) { return $installed[0] }
                    throw [InvalidOperationException]::new("Installation did not provide $target.")
                }
                catch {
                    if ($attempt -eq 3 -or $_.Exception.ToString() -notmatch
                        '(?i)(timed? out|connection (reset|refused)|temporary failure|temporarily unavailable|\b429\b|\b50[234]\b|no route to host|name or service not known)') {
                        throw
                    }
                    Write-Warning "Installing $Name failed transiently (attempt $attempt of 3); checking installed state before retry."
                    Start-Sleep -Seconds (5 * [math]::Pow(2, $attempt - 1))
                }
            }
        }
        catch {
            $lastFailure = $_
            Write-Verbose "PowerShell repository '$($repository.Name)' could not install $target; trying the next configured repository."
        }
    }
    throw $lastFailure
}

function Import-AvmWorkflowPackage {
    [CmdletBinding()]
    param()

    $packages = @(Get-Module -ListAvailable -Name Avm.Authoring | Where-Object {
            $privateData = $_.PrivateData
            if ($privateData -is [Collections.IDictionary] -and $privateData.Contains('PSData')) {
                $psData = $privateData['PSData']
                if ($psData -is [Collections.IDictionary] -and $psData.Contains('Prerelease') -and
                    -not [string]::IsNullOrWhiteSpace([string]$psData['Prerelease'])) {
                    return $false
                }
            }
            return $true
        } | Sort-Object Version -Descending)
    if ($packages.Count -eq 0) {
        throw [InvalidOperationException]::new('No stable installed Avm.Authoring package is available to import.')
    }
    Import-Module -FullyQualifiedName @{ ModuleName = 'Avm.Authoring'; RequiredVersion = $packages[0].Version } `
        -Force -ErrorAction Stop
}

function Initialize-AvmWorkflow {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Static', 'Policy', 'Deployment', 'Matrix', 'Package')]
        [string] $Profile,
        [string] $Path = $PWD.Path
    )

    if (-not $PSCmdlet.ShouldProcess("Bicep $Profile workflow", 'Prepare package and dependencies')) { return }
    $null = Install-AvmWorkflowModule -Name Avm.Authoring -Confirm:$false
    Import-AvmWorkflowPackage
    if ($Profile -ne 'Package') {
        $requiredCapabilities = switch ($Profile) {
            Static { 'BicepPackagedCompliance' }
            Policy { 'PowerShellModuleArchiveRecovery'; 'BicepTestSubscriptionSelection' }
            Matrix { 'BicepTestSubscriptionSelection' }
            Deployment { 'BicepRequiredResourceProviders'; 'BicepTestSubscriptionSelection'; 'BicepAzureDependencyInventory' }
        }
        $package = Get-Module Avm.Authoring | Select-Object -First 1
        $capabilities = if ($null -ne $package -and $package.PrivateData -is [Collections.IDictionary]) {
            $package.PrivateData['AvmCapabilities']
        }
        foreach ($requiredCapability in $requiredCapabilities) {
            if ($capabilities -isnot [Collections.IDictionary] -or
                $capabilities[$requiredCapability] -isnot [int] -or $capabilities[$requiredCapability] -ne 1) {
                throw [InvalidOperationException]::new("The selected package lacks $requiredCapability capability 1; a qualified migration release is required.")
            }
        }
    }
    if ($Profile -in @('Matrix', 'Deployment')) {
        $selector = Get-Command Select-AvmTestSubscription -Module Avm.Authoring -ErrorAction Stop
        foreach ($parameter in @('Path', 'ModulePath', 'Example', 'TestSubscriptionIds', 'RandomSeed', 'CaseIndex', 'SkipModuleVersionCheck')) {
            if (-not $selector.Parameters.ContainsKey($parameter)) {
                throw [InvalidOperationException]::new("The selected package lacks native subscription selection $parameter support.")
            }
        }
    }
    if ($Profile -in @('Static', 'Deployment')) {
        $null = Install-AvmWorkflowModule -Name Pester -Version 5.7.1 -Confirm:$false
    }
    if ($Profile -eq 'Static') {
        $null = Install-AvmWorkflowModule -Name powershell-yaml -Version 0.4.12 -Confirm:$false
    }
    if ($Profile -eq 'Policy') {
        foreach ($parameter in @('Example', 'Baseline')) {
            if (-not (Get-Command Invoke-AvmCheckPolicy -Module Avm.Authoring).Parameters.ContainsKey($parameter)) {
                throw [InvalidOperationException]::new("The selected package lacks Bicep policy $parameter support; a qualified migration release is required.")
            }
        }
        $policyNames = @('PSRule', 'PSRule.Rules.Azure')
        for ($inspection = 0; $inspection -lt 2; $inspection++) {
            $policyTools = @(Get-AvmTool -Name $policyNames -Path $Path -SkipModuleVersionCheck)
            if ($policyTools.Count -ne $policyNames.Count) {
                throw [InvalidOperationException]::new('Managed PSRule preparation requires both selected packages.')
            }
            foreach ($name in $policyNames) {
                if (@($policyTools | Where-Object Name -CEQ $name).Count -ne 1) {
                    throw [InvalidOperationException]::new("Managed PSRule preparation requires exactly one $name result.")
                }
            }
            foreach ($tool in $policyTools) {
                if ($tool.Status -cnotin @('installed', 'installed-on-module-path', 'not-installed')) {
                    throw [InvalidOperationException]::new("Cannot prepare $($tool.Name) with managed status '$($tool.Status)'.")
                }
            }
            $missing = @($policyTools | Where-Object Status -CEQ 'not-installed' | ForEach-Object Name)
            if ($missing.Count -eq 0) { break }
            if ($inspection -gt 0) {
                throw [InvalidOperationException]::new('Managed PSRule preparation did not provide every selected package.')
            }
            $null = Install-AvmTool -Name $missing -Path $Path -SkipModuleVersionCheck -Confirm:$false
        }
    }
    if ($Profile -eq 'Deployment') {
        foreach ($parameter in @('Phase', 'CleanupStatePath', 'UseCiInputs', 'Recurse')) {
            if (-not (Get-Command Invoke-AvmTestE2e -Module Avm.Authoring).Parameters.ContainsKey($parameter)) {
                throw [InvalidOperationException]::new("The selected package lacks native Bicep $parameter support.")
            }
        }
        foreach ($dependency in Get-AvmBicepAzureDependency -SkipModuleVersionCheck) {
            if ($env:AVM_OFFLINE -eq '1' -and @(
                    Get-Module -ListAvailable -Name $dependency.Name |
                        Where-Object { $_.Version -ge $dependency.MinimumVersion }
                ).Count -eq 0) {
                throw [InvalidOperationException]::new("AVM_OFFLINE=1 prevents installing $($dependency.Name).")
            }
            $null = Install-AvmWorkflowModule -Name $dependency.Name -Version $dependency.MinimumVersion -Minimum -Confirm:$false
        }
    }
    if ($Profile -notin @('Package', 'Matrix')) {
        $null = Install-AvmTool -Name bicep -Path $Path -SkipModuleVersionCheck
    }
    $package = Get-Module Avm.Authoring | Select-Object -First 1
    if ($null -eq $package) {
        throw [InvalidOperationException]::new('The latest installed Avm.Authoring package was not imported.')
    }
    Write-AvmWorkflowOutput -Name AVM_AUTHORING_VERSION -Value $package.Version.ToString() -FilePath $env:GITHUB_ENV
}

function Invoke-AvmWorkflowProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [hashtable] $EnvVars = @{},
        [switch] $IgnoreExitCode
    )

    $module = Get-Module Avm.Authoring | Select-Object -First 1
    if ($null -eq $module) {
        throw [InvalidOperationException]::new('Import the pinned Avm.Authoring package before running workflow processes.')
    }
    $executable = (Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $result = & $module {
        param($Executable, $Arguments, $Directory, $Environment, $IgnoreFailure)
        Invoke-AvmProcess -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $Directory `
            -EnvVars $Environment -TimeoutSec 120 -IgnoreExitCode:$IgnoreFailure
    } $executable $ArgumentList $WorkingDirectory $EnvVars ([bool]$IgnoreExitCode)
    $global:LASTEXITCODE = 0
    return $result
}

function Invoke-AvmWorkflowGitRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $Remote,
        [switch] $AllowFailure
    )

    $maximum = if ($Remote) { 3 } else { 1 }
    for ($attempt = 1; $attempt -le $maximum; $attempt++) {
        try {
            $result = Invoke-AvmWorkflowProcess -FilePath git -ArgumentList $Arguments -WorkingDirectory $Root `
                -EnvVars @{ GIT_TERMINAL_PROMPT = '0' } -IgnoreExitCode
        }
        catch [TimeoutException] {
            if ($attempt -eq $maximum) { throw }
            Write-Warning "Git $($Arguments[0]) timed out on attempt $attempt of $maximum; retrying the read."
            Start-Sleep -Seconds (2 * $attempt)
            continue
        }
        if ($result.ExitCode -eq 0) { return $result }
        if ($attempt -lt $maximum) { Start-Sleep -Seconds (2 * $attempt) }
    }
    if ($AllowFailure) { return $result }
    throw [InvalidOperationException]::new("Git $($Arguments[0]) failed after $maximum attempt(s): $($result.StdErr)")
}

function Write-AvmWorkflowResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('static', 'policy', 'deploy', 'complete')] [string] $Name,
        [Parameter(Mandatory)] [object] $Result,
        [Parameter(Mandatory)] [string] $Directory
    )

    $contractError = ''
    if ($null -eq $Result.PSObject.Properties['Status'] -or
        $Result.Status -isnot [string] -or $Result.Status -cnotin @('pass', 'fail', 'error', 'skipped')) {
        $contractError = "$Name returned no inspectable package result status."
    }
    $record = [ordered]@{ Name = $Name; Status = 'error' }
    foreach ($key in @('Status', 'RunsTotal', 'RunsPassed', 'RunsFailed', 'RunsSkipped', 'RunsFiltered',
            'TestsSelected', 'BaselinesExecuted', 'CleanupDeferred', 'CleanupPending')) {
        if ($null -ne $Result.PSObject.Properties[$key]) { $record[$key] = $Result.$key }
    }
    $record.Issues = @(
        if ($null -ne $Result.PSObject.Properties['Issues']) {
            foreach ($issue in $Result.Issues) {
                if ($null -eq $issue -or $issue.Code -isnot [string] -or $issue.Message -isnot [string]) {
                    $contractError = "$Name returned an invalid issue record."
                    continue
                }
                $detail = [ordered]@{ Code = [string]$issue.Code; Message = [string]$issue.Message }
                if ($null -ne $issue.PSObject.Properties['Severity']) { $detail.Severity = [string]$issue.Severity }
                $detail
            }
        }
    )
    if ([string]::IsNullOrEmpty($contractError) -and $record.Status -ceq 'pass') {
        $counts = switch ($Name) {
            static { @('RunsTotal', 'RunsSkipped', 'RunsFiltered') }
            policy { @('TestsSelected', 'BaselinesExecuted') }
            default { @('RunsTotal', 'RunsSkipped') }
        }
        foreach ($count in $counts) {
            if (-not $record.Contains($count) -or
                ($record[$count] -isnot [int] -and $record[$count] -isnot [long]) -or $record[$count] -lt 0) {
                $contractError = "$Name returned no inspectable $count count."
                break
            }
        }
        if ([string]::IsNullOrEmpty($contractError)) {
            if ($Name -eq 'policy' -and ($record.TestsSelected -ne 1 -or $record.BaselinesExecuted -ne 1)) {
                $contractError = 'Each PSRule matrix leg must inspect exactly its selected example and baseline.'
            }
            elseif ($Name -ne 'policy' -and ($record.RunsTotal -lt 1 -or $record.RunsSkipped -gt 0 -or
                    ($Name -eq 'static' -and $record.RunsFiltered -gt 0))) {
                $contractError = 'The selected package tier must execute its complete suite; empty, skipped or filtered runs are not a pass.'
            }
        }
    }
    if (-not [string]::IsNullOrEmpty($contractError)) {
        $record.Status = 'error'
        $record.Issues += [ordered]@{ Code = 'WorkflowResultInvalid'; Message = $contractError; Severity = 'Error' }
    }
    $null = New-Item -ItemType Directory -Path $Directory -Force
    [IO.File]::WriteAllText((Join-Path $Directory "$Name.json"),
        (ConvertTo-Json -InputObject $record -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "### $Name`n`nStatus: $($record.Status)`n`n",
            [Text.UTF8Encoding]::new($false))
    }
    if (-not [string]::IsNullOrEmpty($contractError)) { throw [InvalidOperationException]::new($contractError) }
    if ($record.Status -cne 'pass') {
        throw [InvalidOperationException]::new("$Name did not pass. Inspect its result artifact and package diagnostics.")
    }
}
