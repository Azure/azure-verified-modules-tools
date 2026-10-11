#Requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

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
        [Parameter(Mandatory)] [version] $Version,
        [switch] $Minimum
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object {
                ($Minimum -and $_.Version -ge $Version) -or $_.Version -eq $Version
            } | Sort-Object Version -Descending)
        if ($installed.Count -gt 0) { return $installed[0] }
        if (-not $PSCmdlet.ShouldProcess("$Name $Version", 'Install workflow dependency from PSGallery')) {
            return
        }
        try {
            Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
            $repository = Get-PSResourceRepository -Name PSGallery -ErrorAction Stop
            if ([string]$repository.Uri -cne 'https://www.powershellgallery.com/api/v2') {
                throw [InvalidOperationException]::new('PSGallery must use the official HTTPS repository.')
            }
            Install-PSResource -Name $Name -Version $Version.ToString() -Repository PSGallery `
                -Scope CurrentUser -TrustRepository -Quiet -ErrorAction Stop
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
    $installed = @(Get-Module -ListAvailable -Name $Name | Where-Object {
            ($Minimum -and $_.Version -ge $Version) -or $_.Version -eq $Version
        } | Sort-Object Version -Descending)
    if ($installed.Count -eq 0) {
        throw [InvalidOperationException]::new("Installation did not provide $Name $Version.")
    }
    return $installed[0]
}

function Import-AvmWorkflowPackage {
    [CmdletBinding()]
    param([string] $Version = $env:AVM_AUTHORING_VERSION)

    if ($Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or $Version -ceq '0.0.0') {
        throw [ArgumentException]::new('avm-authoring-version must name an exact, qualified Avm.Authoring release; no release default is provided.')
    }
    Import-Module -FullyQualifiedName @{ ModuleName = 'Avm.Authoring'; RequiredVersion = $Version } -ErrorAction Stop
}

function Initialize-AvmWorkflow {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Version,
        [Parameter(Mandatory)]
        [ValidateSet('Static', 'Policy', 'Deployment', 'Matrix', 'Package')]
        [string] $Profile,
        [string] $Path = $PWD.Path
    )

    if ($Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or $Version -ceq '0.0.0') {
        throw [ArgumentException]::new('Set avm-authoring-version to the exact qualified release before running Bicep workflows.')
    }
    if (-not $PSCmdlet.ShouldProcess("Bicep $Profile workflow", 'Prepare package and dependencies')) { return }
    $null = Install-AvmWorkflowModule -Name Avm.Authoring -Version $Version -Confirm:$false
    Import-AvmWorkflowPackage -Version $Version
    if ($Profile -in @('Static', 'Policy', 'Deployment')) {
        $requiredCapability = switch ($Profile) {
            Static { 'BicepPackagedCompliance' }
            Policy { 'PowerShellModuleArchiveRecovery' }
            Deployment { 'BicepRequiredResourceProviders' }
        }
        $package = Get-Module Avm.Authoring | Where-Object { $_.Version -eq [version]$Version } | Select-Object -First 1
        $capabilities = if ($null -ne $package -and $package.PrivateData -is [Collections.IDictionary]) {
            $package.PrivateData['AvmCapabilities']
        }
        if ($capabilities -isnot [Collections.IDictionary] -or
            $capabilities[$requiredCapability] -isnot [int] -or $capabilities[$requiredCapability] -ne 1) {
            throw [InvalidOperationException]::new("The selected package lacks $requiredCapability capability 1; a qualified migration release is required.")
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
        $null = Install-AvmWorkflowModule -Name Az -Version 15.5.0 -Minimum -Confirm:$false
        $null = Install-AvmWorkflowModule -Name Az.Subscription -Version 0.12.0 -Minimum -Confirm:$false
    }
    if ($Profile -ne 'Package') {
        $null = Install-AvmTool -Name bicep -Path $Path -SkipModuleVersionCheck
    }
    Write-AvmWorkflowOutput -Name AVM_AUTHORING_VERSION -Value $Version -FilePath $env:GITHUB_ENV
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
