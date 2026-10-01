function Copy-AvmBicepPolicySource {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]] $Files,

        [Parameter(Mandatory)]
        [string] $Destination
    )

    Set-StrictMode -Version 3.0
    foreach ($file in $Files) {
        $path = Resolve-AvmArchiveEntryPath -TargetDir $Destination -EntryName $file.RelativePath
        if (-not $PSCmdlet.ShouldProcess($path, 'Stage Bicep source for PSRule')) {
            throw [AvmConfigurationException]::new('PSRule staging was not approved; no baseline ran.')
        }
        $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
        if ($null -eq $file.Text) {
            [System.IO.File]::WriteAllBytes($path, $file.Bytes)
        }
        else {
            [System.IO.File]::WriteAllText($path, $file.Text, [System.Text.UTF8Encoding]::new($false))
        }
    }
}
