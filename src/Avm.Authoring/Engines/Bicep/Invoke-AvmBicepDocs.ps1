function Invoke-AvmBicepDocs {
    <#
    .SYNOPSIS
        Render Bicep module READMEs through the pinned Bicep docs CLI.

    .DESCRIPTION
        Uses the nearest bicepconfig.json and its relative, versioned Scriban
        template. Renders all modules before changing any README; proposed
        modules with no main.bicep are skipped. CheckDrift compares generated
        bytes without writing module files. Authored Notes come only from
        README.notes.md; missing sidecars stop generation. IncludeRenderedContent
        returns the generated strings for independent, in-memory byte comparisons
        and is available only with CheckDrift.
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

        [switch] $IncludeRenderedContent
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

    $tool = Resolve-AvmTool -Name 'bicep' -AllowPathFallback:$AllowPathFallback
    $scopes = @(Get-AvmMetadataScope -Context $Context -IncludeModuleDirectories -IncludeReadmeOnly)
    $plan = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $changed = [System.Collections.Generic.List[string]]::new()
    $notRendered = [System.Collections.Generic.List[string]]::new()
    $renderedReadmes = [System.Collections.Generic.List[object]]::new()
    $filesProcessed = 0
    $filesSelected = 0
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)

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
                        Severity = 'error'
                        Code     = 'avm.bicep.docs-no-source'
                        Message  = "'$relative' has no main.bicep; it was not rendered or compared by Bicep docs and needs an explicit parity policy."
                    })
            }
            continue
        }

        $null = Get-AvmBicepDocsConfiguration -ModulePath $scope.Path
        $sourcePath = $files[0].FullName
        $target = Join-Path -Path $scope.Path -ChildPath 'README.md'
        $relative = [System.IO.Path]::GetRelativePath($Context.Root, $target).Replace('\', '/')
        $filesSelected++
        try {
            $values = Get-AvmBicepDocsCustomValue -ModulePath $scope.Path `
                -RepositoryRoot $Context.Root -ToolPath $tool.Path
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
        $temporaryPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (
            'avm-bicep-docs-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $json = ConvertTo-Json -InputObject $values -Compress -Depth 10
            [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8)
            $result = Invoke-AvmProcess -FilePath $tool.Path -ArgumentList @(
                'docs', 'generate', $sourcePath, '--stdout',
                '--custom-template-value-file-path', $temporaryPath
            ) -WorkingDirectory $scope.Path -IgnoreExitCode
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
        finally {
            if ([System.IO.File]::Exists($temporaryPath)) {
                [System.IO.File]::Delete($temporaryPath)
            }
        }
        $unmappedExample = $null -ne $result.StdOut -and
        $result.StdOut.Contains('__AVM_DOCS_MISSING_EXAMPLE__:')
        $ambiguousRoles = $null -ne $result.StdOut -and
        $result.StdOut.Contains('__AVM_DOCS_AMBIGUOUS_ROLES__:')
        $missingVariant = $null -ne $result.StdOut -and
        $result.StdOut.Contains('__AVM_DOCS_MISSING_VARIANT__:')
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut) -or
            $unmappedExample -or $ambiguousRoles -or $missingVariant) {
            $message = if ($unmappedExample) {
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
            [System.IO.File]::ReadAllBytes($target)
        }
        else {
            $null
        }
        if ($null -ne $current -and
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$current, [byte[]]$expected)) {
            continue
        }

        if ($CheckDrift) {
            $kind = if ($null -eq $current) { 'missing' } else { 'stale' }
            $issues.Add([pscustomobject][ordered]@{
                    File     = $relative
                    Line     = 0
                    Column   = 0
                    Severity = 'error'
                    Code     = "avm.bicep.docs-$kind"
                    Message  = "'$relative' is $kind; run 'avm docs' and commit the generated README.md."
                })
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

    $status = 'pass'
    if ($issues.Count -gt 0) {
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
        Engine           = 'bicep'
        Tool             = ('{0}/{1}' -f $tool.Name, $tool.Version)
        ToolPath         = $tool.Path
        ToolSource       = $tool.Source
        Status           = $status
        FilesSelected    = $filesSelected
        FilesProcessed   = $filesProcessed
        NotRendered      = $notRendered.ToArray()
        Changed          = $changed.ToArray()
        Issues           = $issues.ToArray()
        GeneratedReadmes = $renderedReadmes.ToArray()
    }
}
