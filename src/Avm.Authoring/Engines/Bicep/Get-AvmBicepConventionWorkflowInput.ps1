function Get-AvmBicepConventionWorkflowInput {
    <#
    .SYNOPSIS
        Locate and parse a top-level module's workflow for the convention suite.

    .OUTPUTS
        pscustomobject with Path, FileName, Workflow (null when unusable), and
        Issues describing a missing, linked, mis-cased or unparsable file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Scope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $root = $Scope.RepositoryRoot
    $segments = @($Scope.ModuleRelativePath.Split('/'))
    $fileName = ('avm.{0}.{1}.{2}.yml' -f $segments[1], $segments[2], $segments[3]).ToLowerInvariant()
    $directory = Join-Path -Path $root -ChildPath '.github' -AdditionalChildPath 'workflows'
    $path = Join-Path $directory $fileName
    $result = [pscustomobject]@{
        Path     = $path
        FileName = $fileName
        Workflow = $null
        Issues   = @()
    }

    $parent = $root
    foreach ($segment in @('.github', 'workflows')) {
        $directoryEntries = @(Get-ChildItem -LiteralPath $parent -Force |
                Where-Object { $_.Name -ieq $segment })
        if ($directoryEntries.Count -ne 1 -or -not $directoryEntries[0].PSIsContainer -or
            $directoryEntries[0].Name -cne $segment -or
            ($directoryEntries[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $result.Issues = @(New-AvmBicepConventionIssue -Root $root -Path $path `
                    -Code 'avm.bicep.workflow-file' `
                    -Message "A regular .github/workflows/$fileName with exact casing is required; linked workflow directories are not inspected.")
            return $result
        }
        $parent = $directoryEntries[0].FullName
    }
    $files = @(Get-ChildItem -LiteralPath $directory -Force |
            Where-Object { $_.Name -ieq $fileName })
    if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne $fileName -or
        ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $result.Issues = @(New-AvmBicepConventionIssue -Root $root -Path $path `
                -Code 'avm.bicep.workflow-file' `
                -Message "A regular .github/workflows/$fileName with exact casing is required.")
        return $result
    }

    try {
        $result.Workflow = Get-AvmBicepConventionWorkflow -Path $path -ModuleRoot $root
    }
    catch [AvmConfigurationException] {
        $result.Issues = @(New-AvmBicepConventionIssue -Root $root -Path $path `
                -Code 'avm.bicep.workflow-parse' -Message $_.Exception.Message)
    }
    return $result
}
