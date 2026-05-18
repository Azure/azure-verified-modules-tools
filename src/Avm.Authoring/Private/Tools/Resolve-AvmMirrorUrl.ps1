function Resolve-AvmMirrorUrl {
    <#
    .SYNOPSIS
        Rewrite a canonical source URL through the optional $env:AVM_MIRROR
        proxy, preserving the mirror's path prefix.

    .DESCRIPTION
        Pure helper used by Invoke-AvmHttp. Given a source URL from
        tools.lock.psd1 and a mirror base, produces the URL the downloader
        should actually fetch. The mirror is expected to be a transparent
        HTTPS proxy that mounts upstream binaries under a per-deployment
        prefix (typical Artifactory / Nexus / internal mirror setup).

        Semantics:
          - mirror unset/empty                  -> Source returned unchanged.
          - Source starts with 'file://'        -> Source returned unchanged
            (file:// is the test-fixture path, never proxied).
          - mirror set and Source is https://   -> rewritten to
              '<mirror-scheme>://<mirror-authority><mirror-path><source-path-and-query>'
            where mirror-path is the mirror URL's AbsolutePath with any
            trailing '/' trimmed. Examples:
              mirror = 'https://m.example.com'
              source = 'https://releases.hashicorp.com/terraform/1.9.5/foo.zip'
              ->      'https://m.example.com/terraform/1.9.5/foo.zip'

              mirror = 'https://m.example.com/proxy/'
              source = 'https://releases.hashicorp.com/terraform/1.9.5/foo.zip'
              ->      'https://m.example.com/proxy/terraform/1.9.5/foo.zip'

        Validation:
          - Mirror MUST start with 'https://'. Anything else throws
            AvmConfigurationException (AVM1001) so a misconfigured proxy
            cannot silently downgrade TLS.
          - Mirror MUST parse as an absolute Uri; otherwise the same
            exception is raised with the offending value.

    .PARAMETER Source
        The canonical URL from tools.lock.psd1 (already placeholder-expanded).

    .PARAMETER Mirror
        The raw value of $env:AVM_MIRROR. $null or empty string => no rewrite.

    .OUTPUTS
        [string] The URL to actually download from.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [AllowEmptyString()] [AllowNull()] [string] $Mirror
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Mirror)) {
        return $Source
    }
    if ($Source.StartsWith('file://')) {
        return $Source
    }
    if (-not $Source.StartsWith('https://')) {
        return $Source
    }

    if (-not $Mirror.StartsWith('https://')) {
        throw [AvmConfigurationException]::new(
            "AVM_MIRROR must start with 'https://'. Got: $Mirror")
    }

    $mirrorUri = $null
    if (-not [Uri]::TryCreate($Mirror, [UriKind]::Absolute, [ref] $mirrorUri)) {
        throw [AvmConfigurationException]::new(
            "AVM_MIRROR is not a valid absolute URL: $Mirror")
    }

    $sourceUri = [Uri]::new($Source)
    $mirrorPath = $mirrorUri.AbsolutePath.TrimEnd('/')
    return '{0}://{1}{2}{3}' -f $mirrorUri.Scheme, $mirrorUri.Authority, $mirrorPath, $sourceUri.PathAndQuery
}
