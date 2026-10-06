function Get-AvmBicepTestSourceInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $SourceFile,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, object]] $CompiledTests
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    $source = ''
    $readError = $null
    try {
        $source = Get-AvmBicepCommentFreeSource -Source (
            [System.IO.File]::ReadAllText($SourceFile.Path, [System.Text.UTF8Encoding]::new($false, $true)))
    }
    catch [System.IO.IOException], [System.UnauthorizedAccessException], [System.Text.DecoderFallbackException] {
        $readError = $_.Exception.Message
    }
    $resources = $null
    if ($CompiledTests.ContainsKey($SourceFile.Path)) { $resources = $CompiledTests[$SourceFile.Path]['resources'] }
    $resourceCount = if ($resources -is [System.Collections.IDictionary]) { $resources.psbase.Count }
    elseif ($null -ne $resources) { @($resources).Count }
    else { 0 }
    return @{
        Scope        = $SourceFile.Scope
        IssuePath    = $SourceFile.Path
        Source       = $source
        ReadError    = $readError
        HasResources = $resourceCount -gt 0
        FolderName   = Split-Path (Split-Path $SourceFile.Path -Parent) -Leaf
    }
}
