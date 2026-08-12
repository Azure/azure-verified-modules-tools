function Invoke-AvmPreCommit {
    <#
    .SYNOPSIS
        Run the standard pre-commit gauntlet against the resolved module:
        bicep:     format -> lint -> validate -> docs.
        terraform: sync -> check convention -> transform -> format -> docs.

    .DESCRIPTION
        Composition cmdlet. Resolves the module context once with
        Get-AvmModuleContext, then invokes the per-ecosystem step chain
        in sequence against that same module root. Each step's structured
        result is captured. The overall Status is 'pass' only when every
        executed step reports Status='pass' (format reports an implicit
        pass when no errors are thrown).

        The Terraform chain follows the legacy Terraform governance
        pre-commit.porch.yaml philosophy: after an initial managed-files
        sync it stays fast and fully offline
        (check convention -> transform -> format -> docs), so it
        never needs `terraform init`. The `sync` step runs FIRST so the
        rest of the chain sees the freshest governed files; it fetches the
        managed-file source (the Azure/azure-verified-modules-tools repo by
        default, overridable or pinned to a local path - see Invoke-AvmSync)
        and writes any adds/updates/removals straight into the working tree.
        The two checks that require an
        initialised working directory - lint (tflint) and validate
        (`terraform validate`) - live in `avm pr-check` instead, mirroring
        upstream porch, which runs tflint and the policy/plan checks in
        pr-check rather than pre-commit.

        Status semantics:
          - 'pass'    : step returned Status='pass' (or didn't throw for
                        format).
          - 'fail'    : step returned Status='fail'.
          - 'error'   : step threw any exception other than
                        AvmConfigurationException; the chain aborts.
          - 'skipped' : step threw AvmConfigurationException - the engine
                        is a deliberate placeholder for a future slice
                        (e.g. bicep-docs, terraform transform). The
                        chain CONTINUES and overall status is NOT
                        marked failed by a skip.

        By default the gauntlet is fail-soft: a step that returns
        Status='fail' (e.g. lint diagnostics) does NOT abort subsequent
        steps - the caller gets the full picture in one run. A step that
        THROWS (non-AvmConfigurationException) IS fatal and aborts the
        rest of the chain. Set -StopOnFail to abort on the first
        Status='fail' instead.

        Routed by the dispatcher: 'avm pre-commit'.

    .PARAMETER Path
        Working directory whose enclosing module to validate. Defaults to
        the current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version. Forwarded to each step.

    .PARAMETER StopOnFail
        When set, abort the chain on the first step whose Status is 'fail'.
        A throwing step is always fatal regardless of this flag.

    .PARAMETER ManagedFilesRepo
        owner/name of the git repo holding the managed files. Forwarded only to
        the Terraform sync step.

    .PARAMETER ManagedFilesRef
        Git ref to fetch for the managed files. Forwarded only to the Terraform
        sync step.

    .PARAMETER ManagedFilesPath
        Path within the source repo to the managed-files base folder. Forwarded
        only to the Terraform sync step.

    .PARAMETER ManagedFilesLocalPath
        Direct local path to the managed-files base folder. Skips the managed
        files git fetch and is forwarded only to the Terraform sync step.

    .PARAMETER FileGroupConfigPath
        Path within the managed-files repo to the file-group config that
        declares each group's deleted files. Forwarded only to the Terraform
        sync step.

    .PARAMETER FileGroupConfigLocalPath
        Direct local path to the file-group config file. Forwarded only to the
        Terraform sync step.

    .PARAMETER ConfigRepo
        owner/name of the git repo holding the managed-files config folder.
        Forwarded only to the Terraform sync step.

    .PARAMETER ConfigRef
        Git ref for the config repo. Forwarded only to the Terraform sync step.

    .PARAMETER ConfigPath
        Path within the config repo to the folder holding 'config.json'.
        Forwarded only to the Terraform sync step.

    .PARAMETER ConfigLocalPath
        Direct local path to the managed-files config folder. Skips the config
        repo fetch and is forwarded only to the Terraform sync step.

    .PARAMETER RepoId
        Repository id used to look up overlays/exclusions in config.json.
        Forwarded only to the Terraform sync step.

    .PARAMETER Upgrade
        Move the repository to the latest managed-files release and restamp
        '.avm/managed-files-version.json'. Without it the sync stays on the
        recorded pin and only warns about newer patch or minor releases.
        Forwarded only to the Terraform sync step.

    .PARAMETER SkipManagedFilesVersionCheck
        Skip the managed-files release lookup and sync against whatever ref the
        normal precedence resolves. Forwarded only to the Terraform sync step.

    .OUTPUTS
        pscustomobject with:
          - Path        : the resolved module root
          - Ecosystem   : bicep | terraform
          - Status      : pass | fail | error
          - Steps       : array of { Step, Status, Error?, Result? }
          - DurationMs  : total wall-clock cost

    .EXAMPLE
        avm pre-commit

    .EXAMPLE
        Invoke-AvmPreCommit -Path C:\repos\my-module -StopOnFail

    .EXAMPLE
        avm pre-commit -Ecosystem terraform -ManagedFilesRepo Contoso/governance -ManagedFilesRef v1.2.3 -ConfigRepo Contoso/governance -ConfigRef v1.2.3 -RepoId avm-res-foo

    .EXAMPLE
        avm pre-commit -Ecosystem terraform -ManagedFilesLocalPath D:\gov\managed-files -ConfigLocalPath D:\gov\repository-config -RepoId avm-res-foo
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [switch] $StopOnFail,

        [string] $ManagedFilesRepo,
        [string] $ManagedFilesRef,
        [string] $ManagedFilesPath,
        [string] $ManagedFilesLocalPath,

        [string] $FileGroupConfigPath,
        [string] $FileGroupConfigLocalPath,

        [string] $ConfigRepo,
        [string] $ConfigRef,
        [string] $ConfigPath,
        [string] $ConfigLocalPath,

        [string] $RepoId,

        [switch] $Upgrade,
        [switch] $SkipManagedFilesVersionCheck,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $startTime = [datetime]::UtcNow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem
    Write-AvmLog ("pre-commit: module root = {0}; ecosystem = {1}" -f $context.Root, $context.Ecosystem) -Level Verbose | Out-Null
    $null = Resolve-AvmCommandTool -Command 'pre-commit' -Ecosystem $context.Ecosystem -AllowPathFallback:$AllowPathFallback

    $stepDefs = if ($context.Ecosystem -eq 'terraform') {
        @(
            [pscustomobject]@{ Name = 'sync'; Cmdlet = 'Invoke-AvmSync' }
            [pscustomobject]@{
                Name      = 'check convention'
                Cmdlet    = 'Invoke-AvmCheckConvention'
                ExtraArgs = @{ Fix = $true; FixableOnly = $true }
            }
            [pscustomobject]@{ Name = 'transform'; Cmdlet = 'Invoke-AvmTransform' }
            [pscustomobject]@{ Name = 'format'; Cmdlet = 'Invoke-AvmFormat' }
            [pscustomobject]@{ Name = 'docs'; Cmdlet = 'Invoke-AvmDocs' }
        )
    }
    else {
        @(
            [pscustomobject]@{ Name = 'format'; Cmdlet = 'Invoke-AvmFormat' }
            [pscustomobject]@{ Name = 'lint'; Cmdlet = 'Invoke-AvmLint' }
            [pscustomobject]@{ Name = 'validate'; Cmdlet = 'Invoke-AvmTest' }
            [pscustomobject]@{ Name = 'docs'; Cmdlet = 'Invoke-AvmDocs' }
        )
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $overall = 'pass'
    $stepIndex = 0
    $syncParameterNames = @(
        'ManagedFilesRepo'
        'ManagedFilesRef'
        'ManagedFilesPath'
        'ManagedFilesLocalPath'
        'FileGroupConfigPath'
        'FileGroupConfigLocalPath'
        'ConfigRepo'
        'ConfigRef'
        'ConfigPath'
        'ConfigLocalPath'
        'RepoId'
        'Upgrade'
        'SkipManagedFilesVersionCheck'
    )

    foreach ($def in $stepDefs) {
        $stepStatus = 'pass'
        $stepError = $null
        $stepResult = $null
        $stepIndex++
        $stepStart = [datetime]::UtcNow
        $stepSw = [System.Diagnostics.Stopwatch]::StartNew()

        Write-AvmLog ('step {0}/{1}: {2} (started {3})' -f $stepIndex, $stepDefs.Count, $def.Name, (Format-AvmTimestamp -Timestamp $stepStart)) -Level Info | Out-Null

        try {
            $stepParameters = @{
                Path              = $context.Root
                Ecosystem         = $context.Ecosystem
                AllowPathFallback = $AllowPathFallback
            }
            if ($def.PSObject.Properties.Name -contains 'ExtraArgs') {
                foreach ($parameterName in $def.ExtraArgs.Keys) {
                    $stepParameters[$parameterName] = $def.ExtraArgs[$parameterName]
                }
            }
            if ($def.Name -eq 'sync') {
                foreach ($parameterName in $syncParameterNames) {
                    if ($PSBoundParameters.ContainsKey($parameterName)) {
                        $stepParameters[$parameterName] = $PSBoundParameters[$parameterName]
                    }
                }
            }

            $stepResult = Invoke-AvmNestedCommand {
                & $def.Cmdlet @stepParameters
            }

            # Engine result objects carry their own Status; format does not
            # (it has no concept of failure unless something throws).
            if ($stepResult -and $stepResult.PSObject.Properties.Name -contains 'Status') {
                $stepStatus = $stepResult.Status
            }
        }
        catch [AvmNotSupportedException] {
            # Verb genuinely does not apply to this ecosystem (e.g. bicep-docs).
            # Continue the chain; do not flip overall status.
            $stepStatus = 'skipped'
            $stepError = $_.Exception.Message
        }
        catch [AvmManagedFilesVersionException] {
            # A superseded major is an adoption gap, not a broken environment.
            # Reporting it as fail keeps the message actionable and lets the
            # caller re-run with -Upgrade, where error would read as a defect.
            $stepStatus = 'fail'
            $stepError = $_.Exception.Message
        }
        catch [AvmConfigurationException] {
            # The repo is misconfigured, not unsupported. This must fail rather
            # than skip: a skip renders as a benign gauntlet pass, which is how
            # a step that never actually ran gets to look green.
            $stepStatus = 'fail'
            $stepError = $_.Exception.Message
        }
        catch {
            $stepStatus = 'error'
            $stepError = $_.Exception.Message
        }
        $stepSw.Stop()
        $stepEnd = $stepStart.AddMilliseconds($stepSw.Elapsed.TotalMilliseconds)

        $completionLevel = if ($stepStatus -eq 'pass') { 'Pass' } elseif ($stepStatus -in @('fail', 'error')) { 'Fail' } else { 'Info' }
        Write-AvmLog ('step {0}/{1}: {2} -> {3} ({4})' -f $stepIndex, $stepDefs.Count, $def.Name, $stepStatus, (Format-AvmDuration -Duration $stepSw.Elapsed)) -Level $completionLevel | Out-Null

        if ($stepStatus -in @('fail', 'error') -and -not [string]::IsNullOrWhiteSpace($stepError)) {
            # F41: narration only. Assert-AvmCommandSuccess promotes the same
            # text to the single GitHub Actions annotation for the run.
            Write-AvmLog ('  {0}: {1}' -f $def.Name, $stepError) -Level Fail | Out-Null
        }

        $steps.Add([pscustomobject][ordered]@{
                Step       = $def.Name
                Status     = $stepStatus
                Error      = $stepError
                Result     = $stepResult
                StartTime  = $stepStart
                EndTime    = $stepEnd
                DurationMs = [int]$stepSw.Elapsed.TotalMilliseconds
            })

        if ($stepStatus -eq 'fail' -or $stepStatus -eq 'error') { $overall = $stepStatus }
        if ($stepStatus -eq 'error') { break }
        if ($StopOnFail -and $stepStatus -eq 'fail') { break }
    }

    $sw.Stop()

    return [pscustomobject][ordered]@{
        Path       = $context.Root
        Ecosystem  = $context.Ecosystem
        Status     = $overall
        Steps      = $steps.ToArray()
        StartTime  = $startTime
        EndTime    = $startTime.AddMilliseconds($sw.Elapsed.TotalMilliseconds)
        DurationMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}
