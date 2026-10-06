function Get-AvmBicepPublicationGitState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        $git = Get-Command -Name git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        throw [AvmConfigurationException]::new('Git is required to verify Bicep publication versions.')
    }

    $gitPath = $git.Source
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($remote in @('upstream', 'origin')) {
        $url = Invoke-AvmProcess -FilePath $gitPath -WorkingDirectory $RepositoryRoot `
            -ArgumentList @('remote', 'get-url', $remote) -TimeoutSec 15 -IgnoreExitCode
        if ($url.ExitCode -ne 0 -or
            $url.StdOut.Trim() -cnotmatch '^(?:https://github\.com/|git@github\.com:)Azure/bicep-registry-modules(?:\.git)?\z') {
            continue
        }
        $head = Invoke-AvmProcess -FilePath $gitPath -WorkingDirectory $RepositoryRoot `
            -ArgumentList @('rev-parse', '--verify', '--quiet', "refs/remotes/$remote/main^{commit}") `
            -TimeoutSec 15 -IgnoreExitCode
        if ($head.ExitCode -eq 0 -and $head.StdOut.Trim() -cmatch '^[0-9a-f]{40,64}\z') {
            $candidates.Add($head.StdOut.Trim())
        }
    }
    $gitEnvironment = @{ GIT_TERMINAL_PROMPT = '0'; GCM_INTERACTIVE = 'Never' }
    $upstream = 'https://github.com/Azure/bicep-registry-modules.git'
    $latest = Invoke-AvmProcess -FilePath $gitPath -WorkingDirectory $RepositoryRoot `
        -ArgumentList @('ls-remote', '--heads', $upstream, 'main') -TimeoutSec 30 `
        -IgnoreExitCode -RetryNetworkFailure -EnvVars $gitEnvironment
    if ($latest.ExitCode -ne 0 -or
        $latest.StdOut.Trim() -cnotmatch '^(?<sha>[0-9a-f]{40,64})\trefs/heads/main\z') {
        throw [AvmConfigurationException]::new(
            'Cannot verify the current Azure/bicep-registry-modules main commit; publication targets are unknown.')
    }
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            GitPath        = $gitPath
            RepositoryRoot = $RepositoryRoot
            BaseSha        = $Matches['sha']
            ChangedPaths   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            RemoteFiles    = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        }
    }
    $baseSha = $null
    foreach ($candidate in $candidates) {
        if ($candidate -ceq $Matches['sha']) {
            $baseSha = $candidate
            break
        }
    }
    if ($null -eq $baseSha) {
        throw [AvmConfigurationException]::new(
            'The trusted upstream main tracking ref is stale. Fetch upstream main before checking publication versions.')
    }

    $changed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($arguments in @(
            @('diff', '--diff-filter=AM', '--name-only', '-z', $baseSha, '--', 'avm/'),
            @('ls-files', '--others', '--exclude-standard', '-z', '--', 'avm/')
        )) {
        $result = Invoke-AvmProcess -FilePath $gitPath -WorkingDirectory $RepositoryRoot `
            -ArgumentList $arguments -TimeoutSec 30
        foreach ($path in $result.StdOut.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)) {
            if ($path -cnotmatch '^avm/') {
                throw [AvmConfigurationException]::new(
                    'Git returned a changed path outside avm/ while checking publication versions.')
            }
            $null = $changed.Add($path)
        }
    }

    return [pscustomobject]@{
        GitPath        = $gitPath
        RepositoryRoot = $RepositoryRoot
        BaseSha        = $baseSha
        ChangedPaths   = $changed
    }
}
