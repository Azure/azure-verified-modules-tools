function Get-AvmBicepPolicyConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $directory = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $PSScriptRoot -ChildPath '..' `
            -AdditionalChildPath '..', 'Resources', 'bicep', 'psrule'))
    $optionPath = Join-Path $directory 'ps-rule.yaml'
    $rulePath = Join-Path $directory '.ps-rule'
    if (-not [System.IO.File]::Exists($optionPath) -or
        -not [System.IO.Directory]::Exists($rulePath)) {
        throw [AvmConfigurationException]::new(
            'The installed Avm.Authoring package is missing its Bicep PSRule options or rules. No baseline ran.')
    }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
    else { [System.StringComparison]::Ordinal }
    $root = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..'))
    $ancestor = [System.IO.DirectoryInfo]::new($directory)
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new(
                'Bicep PSRule configuration cannot traverse linked directories.')
        }
        if ([string]::Equals($ancestor.FullName, $root, $comparison)) {
            break
        }
        $ancestor = $ancestor.Parent
    }
    if ($null -eq $ancestor) {
        throw [AvmConfigurationException]::new(
            'Bicep PSRule configuration is outside the installed package.')
    }
    foreach ($itemPath in @($directory, $optionPath, $rulePath)) {
        if ((Get-Item -LiteralPath $itemPath -Force).Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) {
            throw [AvmConfigurationException]::new(
                'Bicep PSRule configuration and rules cannot be linked outside the installed package.')
        }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $rulePath -Recurse -Force)) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
            (-not $entry.PSIsContainer -and $entry.Name -cnotmatch '\.Rule\.yaml$')) {
            throw [AvmConfigurationException]::new(
                'Bicep PSRule rules must be regular .Rule.yaml files under .ps-rule/.')
        }
    }

    $option = New-PSRuleOption -Option $optionPath -ErrorAction Stop
    $selection = @($option.Input.PathIgnore)
    if (-not ($selection -ccontains '*') -or
        -not ($selection -ccontains '!avm/**/defaults/*.test.bicep') -or
        -not ($selection -ccontains '!avm/**/waf-aligned/*.test.bicep') -or
        @($option.Include.Module).Count -ne 1 -or
        $option.Include.Module[0] -cne 'PSRule.Rules.Azure' -or
        -not [string]::IsNullOrWhiteSpace([string]$option.Include.Path) -or
        $option.Rule.IncludeLocal -ne $false -or
        [string]$option.Configuration['AZURE_BICEP_FILE_EXPANSION'] -ne 'true' -or
        [string]$option.Configuration['AZURE_PARAMETER_FILE_EXPANSION'] -ne 'false') {
        throw [AvmConfigurationException]::new(
            'Bicep PSRule configuration must select defaults and waf-aligned tests, use only PSRule.Rules.Azure and packaged YAML rules, enable Bicep expansion, and disable parameter-file expansion.')
    }
    return [pscustomobject]@{
        OptionPath = $optionPath
        RulePath   = $rulePath
        Option     = $option
    }
}
