function Get-AvmBicepE2ePostHook {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $CasePath,

        [Parameter(Mandatory)]
        [string] $ModuleRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = [System.IO.Path]::TrimEndingDirectorySeparator(
        [System.IO.Path]::GetFullPath($ModuleRoot))
    $caseDirectory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($CasePath))
    $relative = [System.IO.Path]::GetRelativePath($root, $caseDirectory)
    if ([System.IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or
        $relative.StartsWith(
            ('..' + [System.IO.Path]::DirectorySeparatorChar),
            [System.StringComparison]::Ordinal) -or $relative -eq '.') {
        throw [AvmConfigurationException]::new(
            "Bicep e2e post hook case is outside the module root: $CasePath")
    }

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $directory = [System.IO.DirectoryInfo]::new($caseDirectory)
    while (-not [string]::Equals(
            [System.IO.Path]::TrimEndingDirectorySeparator($directory.FullName),
            $root, $comparison)) {
        $entry = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
        if (-not $entry.PSIsContainer -or
            ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e post hook case cannot traverse linked directories: $($directory.FullName)")
        }
        $directory = $directory.Parent
    }

    $postEntries = @(Get-ChildItem -LiteralPath $caseDirectory -Force -ErrorAction Stop |
            Where-Object { $_.Name -ieq 'post.ps1' })
    if ($postEntries.Count -eq 0) {
        return $null
    }
    if ($postEntries.Count -ne 1 -or $postEntries[0].Name -cne 'post.ps1' -or
        $postEntries[0].PSIsContainer -or
        ($postEntries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw [AvmConfigurationException]::new(
            "Expected an unlinked post.ps1 file with exact casing in '$caseDirectory'.")
    }
    return $postEntries[0].FullName
}

function Invoke-AvmBicepE2ePostHook {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [string] $ModuleRoot,

        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $RunId,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]] $Issues,

        [string] $TenantId,

        [string] $ManagementGroupId,

        [string] $ResourceGroupName,

        [string] $Location
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $case = $Item.Case.RelativeDirectory
    $result = [ordered]@{
        Case     = $case
        Status   = 'not-present'
        ExitCode = $null
    }
    try {
        $hook = Get-AvmBicepE2ePostHook -CasePath $Item.Case.Path `
            -ModuleRoot $ModuleRoot
        if ($null -eq $hook) {
            return [pscustomobject]$result
        }
        $result.Status = 'fail'
        $pwshPath = [System.Environment]::ProcessPath
        if ([string]::IsNullOrWhiteSpace($pwshPath)) {
            $pwshPath = (Get-Command -Name 'pwsh' -CommandType Application `
                    -ErrorAction Stop).Source
        }
        $environment = @{
            AVM_E2E_CASE                = $case
            AVM_E2E_SCOPE               = $Item.Scope
            AVM_E2E_SUBSCRIPTION_ID     = $SubscriptionId
            AVM_E2E_TENANT_ID           = [string]$TenantId
            AVM_E2E_MANAGEMENT_GROUP_ID = [string]$ManagementGroupId
            AVM_E2E_RESOURCE_GROUP_NAME = [string]$ResourceGroupName
            AVM_E2E_DEPLOYMENT_NAME     = $DeploymentName
            AVM_E2E_RUN_ID              = $RunId
            AVM_E2E_LOCATION            = [string]$Location
        }
        $process = Invoke-AvmProcess -FilePath $pwshPath `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $hook) `
            -WorkingDirectory ([System.IO.Path]::GetDirectoryName($hook)) `
            -EnvVars $environment -TimeoutSec 300 -IgnoreExitCode
        $result.ExitCode = $process.ExitCode
        if ($process.ExitCode -ne 0) {
            Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
                -Code 'post-hook-failed' `
                -Message "Bicep e2e post.ps1 for '$case' exited with code $($process.ExitCode)."
            return [pscustomobject]$result
        }
        $result.Status = 'pass'
    }
    catch [AvmConfigurationException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-invalid' `
            -Message "Refusing Bicep e2e post.ps1 for '$case': $($_.Exception.Message)"
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-invalid' `
            -Message "Bicep e2e post.ps1 for '$case' could not be inspected."
    }
    catch [System.UnauthorizedAccessException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-invalid' `
            -Message "Bicep e2e post.ps1 for '$case' could not be inspected."
    }
    catch [System.IO.IOException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-runner-failed' `
            -Message "Bicep e2e post.ps1 for '$case' could not be inspected or started."
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-runner-failed' `
            -Message "PowerShell was unavailable for Bicep e2e post.ps1 in '$case'."
    }
    catch [AvmProcessException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-runner-failed' `
            -Message "Bicep e2e post.ps1 for '$case' could not start."
    }
    catch [System.TimeoutException] {
        $result.Status = 'fail'
        Add-AvmBicepTestIssue -Issues $Issues -File $Item.Case.RelativePath `
            -Code 'post-hook-timeout' `
            -Message "Bicep e2e post.ps1 for '$case' exceeded its 300-second limit."
    }
    return [pscustomobject]$result
}
