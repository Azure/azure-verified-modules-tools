function Test-AvmTerraformReadDeferred {
    <#
    .SYNOPSIS
        Report whether Terraform defers a data source read until apply.

    .DESCRIPTION
        Terraform reads a data source during plan only when its configuration
        is wholly known. A reference to a managed resource, a module output or
        another data source is not known until apply, and 'depends_on' forces
        the same deferral, so the read never happens during a policy plan.

        This is what makes a large share of AVM examples plannable without a
        credential: an argument such as
        'resource_id = azapi_resource.storage_account.id' cannot be resolved
        at plan time, so Terraform renders 'will be read during apply' and
        moves on.

        Variables and locals are treated as known, because they are. A local
        that is itself built from a resource attribute would be reported as
        not deferred, which errs towards flagging an example rather than
        letting it fail later inside terraform plan.

    .PARAMETER Body
        The data source block body, with comments already stripped.

    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Body
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $false
    }

    # depends_on always defers the read.
    if ([regex]::IsMatch(
            $Body,
            '(?m)^\s*depends_on\s*=',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $true
    }

    # A reference to another data source, e.g. data.azurerm_x.y.id.
    if ([regex]::IsMatch(
            $Body,
            '(?<![\w.])data\.[A-Za-z_][A-Za-z0-9_-]*\.[A-Za-z_]',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $true
    }

    # A module output, e.g. module.key_vault.resource_id.
    if ([regex]::IsMatch(
            $Body,
            '(?<![\w.])module\.[A-Za-z_][A-Za-z0-9_-]*\.[A-Za-z_]',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $true
    }

    # A managed resource attribute, e.g. azapi_resource.storage_account.id.
    # Terraform resource type names always contain an underscore, which
    # distinguishes them from 'var.x.y' and from function calls. 'each',
    # 'self' and 'count' are Terraform's own known-at-plan symbols.
    foreach ($reference in [regex]::Matches(
            $Body,
            '(?<![\w.])(?<type>[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]*)\.(?<name>[A-Za-z_][A-Za-z0-9_-]*)\.[A-Za-z_]',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        if ($reference.Groups['type'].Value -notin @('each', 'self', 'count')) {
            return $true
        }
    }

    return $false
}
