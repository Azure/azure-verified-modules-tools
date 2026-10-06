function Invoke-AvmBicepDocs {
    <#
    .SYNOPSIS
        Render Bicep module READMEs through the pinned Bicep docs CLI.

    .DESCRIPTION
        Uses the nearest bicepconfig.json and its relative, versioned Scriban
        template. Renders all source-backed modules before changing any README;
        source-less READMEs are preserved and reported as not rendered.
        CheckDrift uses packaged Pester 5.5+ requirements to compare generated
        bytes without writing module files.
        A private provenance render identifies generated JSON-example comments
        before accepting omitted complete pairs.
        Authored Notes come only from README.notes.md; missing sidecars stop
        generation. IncludeRenderedContent returns generated strings for
        independent, in-memory byte comparisons and requires CheckDrift.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Noun mirrors the avm CLI verb (avm docs).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [string] $OutputFile = 'README.md',

        [switch] $CheckDrift,

        [switch] $IncludeRenderedContent,

        [switch] $PreparationOnly,

        [AllowEmptyCollection()]
        [object[]] $SelectedScope
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'bicep') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmBicepDocs requires a bicep context (got Ecosystem='$($Context.Ecosystem)').")
    }
    if ($OutputFile -cne 'README.md') {
        throw [System.ArgumentException]::new(
            'Bicep documentation generates README.md in each module; -OutputFile must be README.md.')
    }
    if ($IncludeRenderedContent -and -not $CheckDrift) {
        throw [System.ArgumentException]::new(
            '-IncludeRenderedContent requires -CheckDrift to prevent accidental README writes.')
    }
    if ($PreparationOnly -and -not $CheckDrift) {
        throw [System.ArgumentException]::new('README validation preparation requires -CheckDrift.')
    }

    $tool = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
    $scopes = @(if ($PSBoundParameters.ContainsKey('SelectedScope')) { $SelectedScope } else {
            Get-AvmMetadataScope -Context $Context -IncludeModuleDirectories -IncludeReadmeOnly
        })
    $plan = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $changed = [System.Collections.Generic.List[string]]::new()
    $notRendered = [System.Collections.Generic.List[string]]::new()
    $renderedReadmes = [System.Collections.Generic.List[object]]::new()
    $readmeInputs = [System.Collections.Generic.List[object]]::new()
    $validationSummary = $null
    $filesProcessed = 0
    $filesSelected = 0
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $pathComparer = if ($IsWindows) {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    else { [System.StringComparer]::Ordinal }
    $compiledTemplates = [System.Collections.Generic.Dictionary[string, object]]::new(
        $pathComparer)

    foreach ($scope in $scopes) {
        $files = @(Get-ChildItem -LiteralPath $scope.Path -Force |
                Where-Object { $_.Name -ieq 'main.bicep' })
        if ($files.Count -gt 0 -and
            ($files.Count -ne 1 -or $files[0].PSIsContainer -or
            $files[0].Name -cne 'main.bicep' -or
            ($files[0].Attributes -band [System.IO.FileAttributes]::ReparsePoint))) {
            throw [AvmConfigurationException]::new(
                "Bicep documentation needs a regular main.bicep with exact casing in '$($scope.Path)'.")
        }
        if ($files.Count -eq 0) {
            if (Test-Path -LiteralPath (Join-Path $scope.Path 'README.md')) {
                $relative = [System.IO.Path]::GetRelativePath(
                    $Context.Root, (Join-Path $scope.Path 'README.md')).Replace('\', '/')
                $notRendered.Add($relative)
                $issues.Add([pscustomobject][ordered]@{
                        File     = $relative
                        Line     = 0
                        Column   = 0
                        Severity = 'warning'
                        Code     = 'avm.bicep.docs-no-source'
                        Message  = "'$relative' has no main.bicep; it is preserved but not rendered or compared by Bicep docs."
                    })
            }
            continue
        }

        $docsConfiguration = Get-AvmBicepDocsConfiguration -ModulePath $scope.Path
        $sourcePath = $files[0].FullName
        $target = Join-Path -Path $scope.Path -ChildPath 'README.md'
        $relative = [System.IO.Path]::GetRelativePath($Context.Root, $target).Replace('\', '/')
        $filesSelected++
        try {
            $values = Get-AvmBicepDocsCustomValue -ModulePath $scope.Path `
                -RepositoryRoot $Context.Root -ToolPath $tool.Path `
                -CompiledTemplateCache $compiledTemplates
        }
        catch [AvmProcessException], [AvmConfigurationException] {
            if (-not $CheckDrift) {
                throw
            }
            $issues.Add([pscustomobject][ordered]@{
                    File     = $relative
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = 'avm.bicep.docs-render-failed'
                    Message  = "Bicep docs could not prepare '$relative': $($_.Exception.Message)"
                })
            continue
        }
        try {
            $result = Invoke-AvmBicepDocsRender -Values $values -SourcePath $sourcePath `
                -TemplatePath $docsConfiguration.TemplatePath -ToolPath $tool.Path -WorkingDirectory $scope.Path
        }
        catch [AvmProcessException] {
            if (-not $CheckDrift) {
                throw
            }
            $issues.Add([pscustomobject][ordered]@{
                    File     = $relative
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = 'avm.bicep.docs-render-failed'
                    Message  = "Bicep docs could not start for '$relative': $($_.Exception.Message)"
                })
            continue
        }
        $unmappedExample = $null -ne $result.StdOut -and
        $result.StdOut.Contains('__AVM_DOCS_MISSING_EXAMPLE__:')
        $ambiguousRoles = $null -ne $result.StdOut -and
        $result.StdOut.Contains('__AVM_DOCS_AMBIGUOUS_ROLES__:')
        $missingVariant = $null -ne $result.StdOut -and
        $result.StdOut.Contains('__AVM_DOCS_MISSING_VARIANT__:')
        $invalidExample = [regex]::Match(
            [string]$result.StdOut, '(?m)^__AVM_DOCS_INVALID_EXAMPLE__:(.*)$')
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut) -or
            $unmappedExample -or $ambiguousRoles -or $missingVariant -or
            $invalidExample.Success) {
            $message = if ($invalidExample.Success) {
                "Bicep docs could not render '$relative': $($invalidExample.Groups[1].Value.Trim())"
            }
            elseif ($unmappedExample) {
                "Bicep docs included an example without a matching source for '$relative'. Check tests/e2e and bicepconfig.json scope reassignments."
            }
            elseif ($ambiguousRoles) {
                "Bicep docs found conflicting compiled role names for a documented roleAssignments parameter in '$relative'."
            }
            elseif ($missingVariant) {
                "Bicep docs discriminator variants differ from the compiled Bicep mapping in '$relative'."
            }
            else {
                Add-AvmProcessFailureDetail `
                    -Message "Bicep docs did not render a README for '$sourcePath' (exit $($result.ExitCode))." `
                    -StdOut $result.StdOut -StdErr $result.StdErr
            }
            if ($CheckDrift) {
                $issues.Add([pscustomobject][ordered]@{
                        File     = $relative
                        Line     = 0
                        Column   = 0
                        Severity = 'error'
                        Code     = 'avm.bicep.docs-render-failed'
                        Message  = $message
                    })
                continue
            }
            throw [AvmConfigurationException]::new($message)
        }

        $filesProcessed++
        if ($IncludeRenderedContent) {
            $renderedReadmes.Add([pscustomobject]@{
                    Path    = $relative
                    Content = $result.StdOut
                })
        }
        $expected = $utf8.GetBytes($result.StdOut)
        $current = if ([System.IO.File]::Exists($target)) {
            , [System.IO.File]::ReadAllBytes($target)
        }
        else {
            $null
        }
        $readmeCase = $null
        if ($CheckDrift) {
            $readmeCase = @{
                Current                = $current
                Expected               = $expected
                MissingExampleComments = 0
            }
            $readmeInputs.Add(@{ Case = $readmeCase; IssuePath = $target })
        }
        if ($null -ne $current -and
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$current, [byte[]]$expected)) {
            continue
        }
        $missingExampleComments = 0
        if ($CheckDrift -and $null -ne $current) {
            $probe = Get-AvmBicepDocsExampleCommentProbe `
                -Values $values -GeneratedContent $result.StdOut
            if ($null -ne $probe) {
                try {
                    $probeResult = Invoke-AvmBicepDocsRender -Values $probe.Values `
                        -SourcePath $sourcePath -ToolPath $tool.Path `
                        -TemplatePath $docsConfiguration.TemplatePath -WorkingDirectory $scope.Path
                }
                catch [AvmProcessException] {
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $relative
                            Line     = 0
                            Column   = 0
                            Severity = 'error'
                            Code     = 'avm.bicep.docs-provenance-failed'
                            Message  = "Bicep docs could not verify generated comments in '$relative': $($_.Exception.Message)"
                        })
                    continue
                }
                if ($probeResult.ExitCode -ne 0 -or
                    [string]::IsNullOrWhiteSpace($probeResult.StdOut)) {
                    $message = Add-AvmProcessFailureDetail `
                        -Message "Bicep docs provenance render failed for '$relative' (exit $($probeResult.ExitCode))." `
                        -StdOut $probeResult.StdOut -StdErr $probeResult.StdErr
                    $issues.Add([pscustomobject][ordered]@{
                            File     = $relative
                            Line     = 0
                            Column   = 0
                            Severity = 'error'
                            Code     = 'avm.bicep.docs-provenance-failed'
                            Message  = $message
                        })
                    continue
                }
                $missingExampleComments = Get-AvmBicepDocsExampleCommentDifferenceCount `
                    -CurrentBytes $current -GeneratedContent $result.StdOut `
                    -ProbeContent $probeResult.StdOut -Markers $probe.Markers
            }
        }
        if ($missingExampleComments -gt 0) {
            $readmeCase.MissingExampleComments = $missingExampleComments
            continue
        }

        if ($CheckDrift) {
            continue
        }

        $original = $null
        if ($null -ne $current) {
            try {
                $original = $utf8.GetString($current)
            }
            catch [System.Text.DecoderFallbackException] {
                throw [AvmConfigurationException]::new(
                    "Bicep README must contain valid UTF-8: $target")
            }
        }
        $plan.Add([pscustomobject]@{
                Path     = $target
                Original = $original
                Content  = $result.StdOut
            })
        $changed.Add($relative)
    }

    if ($PreparationOnly) {
        return [pscustomobject]@{ ReadmeInputs = $readmeInputs.ToArray(); Issues = $issues.ToArray() }
    }
    if ($CheckDrift -and $readmeInputs.Count -gt 0) {
        $convention = @{
            Root                 = $Context.Root
            ReadmeInputs         = $readmeInputs.ToArray()
            NativeReadmeExpected = -1
        }
        $suite = Join-Path -Path $PSScriptRoot -ChildPath '..' `
            -AdditionalChildPath '..', 'Resources', 'bicep', 'conventions', 'Readme.Tests.ps1'
        $validationSummary = Invoke-AvmBicepPesterSuite -Files @($suite) -WorkingDirectory $Context.Root `
            -Mode Convention -ConventionData $convention -EnvVars @{} -InProcess
        foreach ($issue in @($validationSummary.Issues)) {
            $issuePath = if ([string]::IsNullOrWhiteSpace($issue.File)) { $Context.Root } else { $issue.File }
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root -Path $issuePath `
                        -Code $issue.Code -Message $issue.Message -Severity $issue.Severity -Line $issue.Line))
        }
        if ($convention.NativeReadmeExpected -lt $readmeInputs.Count -or
            $validationSummary.Total -ne $convention.NativeReadmeExpected -or
            $validationSummary.Failed -gt @($validationSummary.Issues | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and $_.Contains('NativeConvention') -and $_.NativeConvention
                }).Count -or
            $validationSummary.Passed + $validationSummary.Failed -ne $convention.NativeReadmeExpected) {
            $issues.Add((New-AvmBicepConventionIssue -Root $Context.Root -Path $Context.Root `
                        -Code 'avm.bicep.docs-suite-incomplete' -Message 'The packaged README suite did not execute all intended requirements.'))
        }
    }
    $status = 'pass'
    if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) {
        $status = 'fail'
        $changed.Clear()
    }
    elseif ($plan.Count -gt 0) {
        Test-AvmModuleInitializationPlan -Root $Context.Root -Plan $plan.ToArray()
        if ($PSCmdlet.ShouldProcess(($changed -join ', '), 'Write generated Bicep READMEs')) {
            $null = Write-AvmModuleInitializationPlan -Root $Context.Root -Plan $plan.ToArray() -Confirm:$false
        }
        else {
            $status = 'skipped'
            $changed.Clear()
        }
    }

    return [pscustomobject][ordered]@{
        Engine            = 'bicep'
        Tool              = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath          = $tool.Path
        ToolSource        = $tool.Source
        Status            = $status
        FilesSelected     = $filesSelected
        FilesProcessed    = $filesProcessed
        NotRendered       = $notRendered.ToArray()
        Changed           = $changed.ToArray()
        Issues            = $issues.ToArray()
        GeneratedReadmes  = $renderedReadmes.ToArray()
        ValidationSummary = $validationSummary
    }
}
