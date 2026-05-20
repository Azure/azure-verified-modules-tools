function Get-AvmVerbRegistry {
    <#
    .SYNOPSIS
        Returns the verb -> cmdlet routing table for the avm CLI.

    .DESCRIPTION
        Single source of truth for which CLI verbs the dispatcher knows about.
        Each entry has:
          - Path:    array of lowercase verb tokens, e.g. @('tool', 'install').
          - Cmdlet:  the approved-verb cmdlet name to invoke.
          - Summary: one-line help string used by 'avm' with no arguments.

        Tokens are matched case-sensitively to keep the CLI surface
        predictable across case-sensitive (Linux) and case-preserving
        (Windows / macOS) filesystems and shells.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    [pscustomobject[]]@(
        [pscustomobject]@{
            Path    = [string[]]@('version')
            Cmdlet  = 'Get-AvmVersion'
            Summary = 'Print module, runtime and OS version info.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('doctor')
            Cmdlet  = 'Invoke-AvmDoctor'
            Summary = 'Diagnose the local environment.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('tool', 'list')
            Cmdlet  = 'Get-AvmTool'
            Summary = 'List managed tools and their install status.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('tool', 'which')
            Cmdlet  = 'Get-AvmTool'
            Summary = 'Show the cached path for a managed tool.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('tool', 'install')
            Cmdlet  = 'Install-AvmTool'
            Summary = 'Download and verify a managed tool into the cache.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('context')
            Cmdlet  = 'Get-AvmModuleContext'
            Summary = 'Classify the current directory as a Bicep or Terraform module.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('format')
            Cmdlet  = 'Invoke-AvmFormat'
            Summary = 'Format the current module via the resolved engine.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('lint')
            Cmdlet  = 'Invoke-AvmLint'
            Summary = 'Lint the current module via the resolved engine.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('test')
            Cmdlet  = 'Invoke-AvmTest'
            Summary = 'Build/validate the current module via the resolved engine.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('docs')
            Cmdlet  = 'Invoke-AvmDocs'
            Summary = 'Generate or refresh README docs via the resolved engine.'
        }
        [pscustomobject]@{
            Path    = [string[]]@('transform')
            Cmdlet  = 'Invoke-AvmTransform'
            Summary = 'Regenerate README + test scaffolding (Phase 1 stub).'
        }
        [pscustomobject]@{
            Path    = [string[]]@('check', 'policy')
            Cmdlet  = 'Invoke-AvmCheckPolicy'
            Summary = 'Run policy checks (PSRule.Rules.Azure / Conftest; Phase 1 stub).'
        }
        [pscustomobject]@{
            Path    = [string[]]@('check', 'convention')
            Cmdlet  = 'Invoke-AvmCheckConvention'
            Summary = 'Run convention checks (compliance Pester / grept; Phase 1 stub).'
        }
        [pscustomobject]@{
            Path    = [string[]]@('pre-commit')
            Cmdlet  = 'Invoke-AvmPreCommit'
            Summary = 'Run format + lint + test as a pre-commit gauntlet.'
        }
    )
}
