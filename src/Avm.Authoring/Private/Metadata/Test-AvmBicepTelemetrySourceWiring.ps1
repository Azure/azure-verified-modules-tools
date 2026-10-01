function Test-AvmBicepTelemetrySourceWiring {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Source
    )

    $head = "(?m)^[\t ]*resource[\t ]+avmTelemetry[\t ]+'Microsoft\.Resources/deployments@[^']+'[^\r\n]*\{\s*name[\t ]*:[\t ]*'"
    $forms = @(
        @{ Declaration = "var telemetryIdPrefix = loadJsonContent('metadata.json', 'telemetryIdPrefix')"; Reference = '${telemetryIdPrefix}' }
        @{ Declaration = "var avmTelemetryIdPrefix = loadJsonContent('metadata.json', '$.telemetryIdPrefix')"; Reference = '${avmTelemetryIdPrefix}' }
    )
    foreach ($form in $forms) {
        if ($Source.Contains($form.Declaration) -and
            [regex]::IsMatch($Source, $head + [regex]::Escape($form.Reference) + '\.')) {
            return $true
        }
    }
    return $false
}
