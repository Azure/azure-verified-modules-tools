function Invoke-AvmTestE2e {
    <#
    .SYNOPSIS
        Run the module's end-to-end (e2e) test tier by deploying, checking
        idempotency, and destroying each example under examples/.

    .DESCRIPTION
        Terraform-only test tier. Resolves the enclosing module via
        Get-AvmModuleContext, then hands off to Invoke-AvmTerraformTestE2e,
        which walks each runnable example under examples/ and runs
        init -> apply -> idempotency plan -> destroy against a real backend.

        Unlike the unit and integration tiers (which run 'terraform test'
        against tests/<tier>/), the e2e tier provisions and then tears down
        real infrastructure from the module's examples. It therefore needs
        valid cloud credentials at runtime (for example an authenticated 'az'
        session or ARM_* environment variables). Authentication is left to
        terraform and its providers; this verb performs no preflight.

        An example directory can opt out of the e2e run by containing a
        '.e2eignore' marker file. Modules that ship no runnable example report
        a clean pass with FilesProcessed = 0.

        Use -Example to target one or more named examples (this is how the
        reusable workflow fans the tier out across a matrix), and -List to
        discover the runnable example names as JSON.

        An apply that fails on region or SKU capacity is retried: the example
        is destroyed and redeployed up to -MaxRetry times. Retries are recorded
        as warning-level Issues, so a recovered example stays green while the
        flake remains visible. The idempotency check is never retried.

        This verb is a standalone command; it is NOT part of the offline
        pre-commit / pr-check chains, which keep the validate-only 'test'.

        Routed by the dispatcher: 'avm test e2e'.

    .PARAMETER Path
        Working directory whose enclosing module to test. Defaults to the
        current location.

    .PARAMETER Ecosystem
        Force the ecosystem selector. Defaults to 'auto'. Bicep modules are
        rejected: the e2e test tier is terraform-only.

    .PARAMETER AllowPathFallback
        When set, accept a PATH-resolved tool binary that self-reports the
        lock-pinned version.

    .PARAMETER Example
        Restrict the run to the named examples. Accepts either the folder leaf
        ('example-a') or a repo-relative path ('examples/example-a'). Omitted,
        every runnable example is processed sequentially, which is the local
        default. A name that does not exist, or that carries a '.e2eignore'
        marker, is a hard error rather than a silent skip, so a stale CI matrix
        can never quietly drop a test.

    .PARAMETER List
        Emit a compact JSON array of runnable example names (honouring
        '.e2eignore') and nothing else, then return. Intended to feed a
        GitHub Actions matrix via fromJson(). Emits '[]' when the module ships
        no runnable example. Does not resolve or install terraform.

    .PARAMETER MaxRetry
        How many times to retry an example whose 'terraform apply' failed with
        a transient capacity or quota error. Defaults to 2 (up to three
        attempts in total); 0 disables retries. Each retry destroys the example
        before redeploying, so the region is re-rolled against an empty state.
        Retries are recorded as warnings and do not fail the run.

    .OUTPUTS
        pscustomobject from the engine: Engine, Tool, ToolPath, ToolSource,
        Status, FilesProcessed, Issues.

    .EXAMPLE
        avm test e2e

    .EXAMPLE
        avm test e2e -MaxRetry 0

    .EXAMPLE
        avm test e2e --example example-a

    .EXAMPLE
        avm test e2e --list

    .EXAMPLE
        Invoke-AvmTestE2e -Path C:\repos\terraform-azurerm-avm-res-foo
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = $PWD.Path,

        [ValidateSet('auto', 'bicep', 'terraform')]
        [string] $Ecosystem = 'auto',

        [switch] $AllowPathFallback,

        [AllowEmptyCollection()]
        [string[]] $Example = @(),

        [switch] $List,

        [ValidateRange(0, 10)]
        [int] $MaxRetry = 2
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $context = Get-AvmModuleContext -Path $Path -Ecosystem $Ecosystem

    switch ($context.Ecosystem) {
        'terraform' {
            Invoke-AvmTerraformTestE2e -Context $context -AllowPathFallback:$AllowPathFallback -Example $Example -List:$List -MaxRetry $MaxRetry
        }
        default {
            throw [AvmNotSupportedException]::new(
                "avm test e2e is a terraform-only tier; the resolved module ecosystem is '$($context.Ecosystem)'. Bicep e2e-test tiers are not implemented.")
        }
    }
}
