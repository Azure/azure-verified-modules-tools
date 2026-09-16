function Get-AvmBicepCommentFreeSource {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Source
    )

    $pattern = "(?<comment>/\*[\s\S]*?\*/|//[^\r\n]*)|'''[\s\S]*?'''|'(?:\\.|[^'\\\r\n])*'"
    return [regex]::Replace($Source, $pattern, [System.Text.RegularExpressions.MatchEvaluator] {
            param($token)
            if ($token.Groups['comment'].Success) {
                return [regex]::Replace($token.Value, '[^\r\n]', ' ')
            }
            return $token.Value
        })
}
