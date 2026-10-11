function Write-AvmToolVersionOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Tool
    )

    if (-not $Tool.ContainsKey('versionOverride')) { return }
    Write-AvmLog (
        "tools: OVERRIDE {0}: packaged {1} -> selected {2}; source: {3}. Pinned checksum verification is DISABLED for this tool." -f
        $Tool.name, $Tool.versionOverride.PackagedVersion, $Tool.version, $Tool.versionOverride.Path
    ) -Level Warning | Out-Null
}
