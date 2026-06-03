function New-AvmRule {
    <#
    .SYNOPSIS
        Construct an AvmRule pscustomobject from a raw definition hashtable.

    .DESCRIPTION
        Used by Read-AvmRuleSet (and by tests) to normalise an authored rule
        definition (typically a hashtable loaded from a .psd1) into the
        canonical AvmRule shape. Defaults are filled in (Severity='error',
        AppliesTo='root') and the result is validated by Test-AvmRule before
        return.

        Authored shape (see docs/quality-standards.md Appendix A for the
        canonical rule list):

            @{
                Id          = 'avm.tf.outputs-tf-not-output-tf'
                Kind        = 'FileMustNotExist'  # one of the primitive kinds
                Description = 'output.tf should be renamed to outputs.tf'
                Severity    = 'error' | 'warning'           # optional, default 'error'
                Parameters  = @{ Path = 'output.tf'; ... }  # kind-specific
                AppliesTo   = 'root' | 'examples' | 'modules' | 'all'  # optional, default 'root'
            }

        Returned canonical shape (PascalCase, all fields populated):

            [pscustomobject]@{
                Id          = '<authored>'
                Kind        = '<authored>'
                Description = '<authored>'
                Severity    = 'error' | 'warning'
                Parameters  = @{ <kind-specific> }
                AppliesTo   = 'root' | 'examples' | 'modules' | 'all'
                Source      = '<full path to .psd1>' | $null
            }

    .PARAMETER Definition
        Hashtable carrying the authored fields.

    .PARAMETER Source
        Optional full path to the .psd1 file the definition came from. The
        loader stamps this so error messages can cite the offending file.

    .OUTPUTS
        Single pscustomobject. Throws [System.Data.DataException] if the
        definition fails Test-AvmRule.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Factory function; returns a new pscustomobject and mutates no external state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Definition,

        [string] $Source
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmRule -Definition $Definition | Out-Null

    $severity = if ($Definition.ContainsKey('Severity')) { [string]$Definition.Severity } else { 'error' }
    $appliesTo = if ($Definition.ContainsKey('AppliesTo')) { [string]$Definition.AppliesTo } else { 'root' }
    $parameters = if ($Definition.ContainsKey('Parameters')) { $Definition.Parameters } else { @{} }

    return [pscustomobject][ordered]@{
        Id          = [string]$Definition.Id
        Kind        = [string]$Definition.Kind
        Description = [string]$Definition.Description
        Severity    = $severity
        Parameters  = $parameters
        AppliesTo   = $appliesTo
        Source      = if ($Source) { [string]$Source } else { $null }
    }
}

function Test-AvmRule {
    <#
    .SYNOPSIS
        Validate a hashtable that purports to be an AvmRule definition.

    .DESCRIPTION
        Throws [System.Data.DataException] with a precise message on schema
        violation; returns $true on success so it can be used in an
        assertion-style pipe (`Test-AvmRule -Definition $d | Out-Null`).

        Schema:
          - Id          : required, lowercase kebab/dot identifier
                          (^[a-z][a-z0-9.-]*$), unique within the loaded set.
          - Kind        : required, one of the four primitive kinds:
                          FileMustNotExist, FileMustExist, DirectoryMustExist,
                          GitignoreMustContain.
          - Description : required, non-empty string.
          - Severity    : optional, 'error' | 'warning' (default 'error').
          - AppliesTo   : optional, 'root' | 'examples' | 'modules' | 'all'
                          (default 'root').
          - Parameters  : required hashtable; per-kind required keys:
              FileMustNotExist     : Path (string). Optional: FixRenameTo (string).
              FileMustExist        : Path (string).
              DirectoryMustExist   : Path (string).
              GitignoreMustContain : RequiredGlobs (string[]), at least one entry.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable] $Definition
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'

        $idRegex = '^[a-z][a-z0-9.-]*$'
        $validKinds = @('FileMustNotExist', 'FileMustExist', 'DirectoryMustExist', 'GitignoreMustContain')
        $validSeverities = @('error', 'warning')
        $validAppliesTo = @('root', 'examples', 'modules', 'all')
        $knownKeys = @('Id', 'Kind', 'Description', 'Severity', 'Parameters', 'AppliesTo')
    }

    process {
        foreach ($k in $Definition.Keys) {
            if ($knownKeys -cnotcontains $k) {
                throw [System.Data.DataException]::new(
                    "avm-rule: unknown key '$k'. Allowed: $($knownKeys -join ', ').")
            }
        }

        if (-not $Definition.ContainsKey('Id') -or [string]::IsNullOrWhiteSpace([string]$Definition.Id)) {
            throw [System.Data.DataException]::new("avm-rule: missing required key 'Id'.")
        }
        $id = [string]$Definition.Id
        if ($id -cnotmatch $idRegex) {
            throw [System.Data.DataException]::new(
                "avm-rule: Id '$id' must match $idRegex (lowercase, kebab/dot).")
        }

        if (-not $Definition.ContainsKey('Kind') -or [string]::IsNullOrWhiteSpace([string]$Definition.Kind)) {
            throw [System.Data.DataException]::new("avm-rule '$id': missing required key 'Kind'.")
        }
        $kind = [string]$Definition.Kind
        if ($validKinds -cnotcontains $kind) {
            throw [System.Data.DataException]::new(
                "avm-rule '$id': Kind '$kind' is not one of: $($validKinds -join ', ').")
        }

        if (-not $Definition.ContainsKey('Description') -or [string]::IsNullOrWhiteSpace([string]$Definition.Description)) {
            throw [System.Data.DataException]::new("avm-rule '$id': missing required key 'Description'.")
        }

        if ($Definition.ContainsKey('Severity')) {
            $sev = [string]$Definition.Severity
            if ($validSeverities -cnotcontains $sev) {
                throw [System.Data.DataException]::new(
                    "avm-rule '$id': Severity '$sev' is not one of: $($validSeverities -join ', ').")
            }
        }

        if ($Definition.ContainsKey('AppliesTo')) {
            $at = [string]$Definition.AppliesTo
            if ($validAppliesTo -cnotcontains $at) {
                throw [System.Data.DataException]::new(
                    "avm-rule '$id': AppliesTo '$at' is not one of: $($validAppliesTo -join ', ').")
            }
        }

        if (-not $Definition.ContainsKey('Parameters')) {
            throw [System.Data.DataException]::new("avm-rule '$id': missing required key 'Parameters'.")
        }
        $params = $Definition.Parameters
        if ($params -isnot [System.Collections.IDictionary]) {
            throw [System.Data.DataException]::new(
                "avm-rule '$id': 'Parameters' must be a hashtable.")
        }

        switch ($kind) {
            'FileMustNotExist' {
                if (-not $params.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace([string]$params.Path)) {
                    throw [System.Data.DataException]::new(
                        "avm-rule '$id': FileMustNotExist requires Parameters.Path.")
                }
                if ($params.ContainsKey('FixRenameTo') -and [string]::IsNullOrWhiteSpace([string]$params.FixRenameTo)) {
                    throw [System.Data.DataException]::new(
                        "avm-rule '$id': FileMustNotExist FixRenameTo must not be empty when provided.")
                }
            }
            'FileMustExist' {
                if (-not $params.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace([string]$params.Path)) {
                    throw [System.Data.DataException]::new(
                        "avm-rule '$id': FileMustExist requires Parameters.Path.")
                }
            }
            'DirectoryMustExist' {
                if (-not $params.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace([string]$params.Path)) {
                    throw [System.Data.DataException]::new(
                        "avm-rule '$id': DirectoryMustExist requires Parameters.Path.")
                }
            }
            'GitignoreMustContain' {
                if (-not $params.ContainsKey('RequiredGlobs')) {
                    throw [System.Data.DataException]::new(
                        "avm-rule '$id': GitignoreMustContain requires Parameters.RequiredGlobs.")
                }
                $globs = @($params.RequiredGlobs)
                if ($globs.Count -eq 0) {
                    throw [System.Data.DataException]::new(
                        "avm-rule '$id': GitignoreMustContain RequiredGlobs must have at least one entry.")
                }
                foreach ($g in $globs) {
                    if ([string]::IsNullOrWhiteSpace([string]$g)) {
                        throw [System.Data.DataException]::new(
                            "avm-rule '$id': GitignoreMustContain RequiredGlobs entries must be non-empty.")
                    }
                }
            }
        }

        return $true
    }
}
