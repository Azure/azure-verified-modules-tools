BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    Import-Module (Join-Path $root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    $sharedLib = Join-Path $root 'repository-management' 'repository-sync' 'scripts' 'lib'
    $lib = Join-Path $root 'repository-management' 'reviewer-routing' 'scripts' 'lib'
    . (Join-Path $sharedLib 'RetryHelpers.ps1')
    . (Join-Path $sharedLib 'RepoTree.ps1')
    . (Join-Path $lib 'RepositoryFileAccess.ps1')

    function script:New-FileFixture {
        param([string] $Content)
        $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($Content)
        [pscustomobject]@{
            Bytes = $bytes
            Sha = Get-RepositoryGitBlobSha -Bytes $bytes
        }
    }
}

Describe 'Get-AvmRepositoryFileAtRef' {
    It 'decodes an inline base64 response for a small file' {
        $fixture = New-FileFixture -Content 'small file content'
        $metadata = @{
            type = 'file'; path = 'metadata.json'; sha = $fixture.Sha
            size = $fixture.Bytes.Length; encoding = 'base64'
            content = [System.Convert]::ToBase64String($fixture.Bytes)
        } | ConvertTo-Json -Depth 5
        Mock Invoke-RepositorySyncProcess { @{ ExitCode = 0; StdOut = $metadata; StdErr = '' } }

        $result = Get-AvmRepositoryFileAtRef -Repository 'Azure/bicep-registry-modules' -Path 'metadata.json' -Ref 'main'
        $result.Content | Should -Be 'small file content'
        $result.Sha | Should -Be $fixture.Sha
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 1
    }

    It 'falls back to a raw-media-type request for a file over the 1 MB inline limit' {
        $fixture = New-FileFixture -Content 'large catalog content'
        $metadata = @{
            type = 'file'; path = 'docs/static/module-indexes/v1/modules.json'; sha = $fixture.Sha
            size = $fixture.Bytes.Length; encoding = 'none'; content = ''
        } | ConvertTo-Json -Depth 5
        Mock Invoke-RepositorySyncProcess {
            param($Command, $Arguments)
            if ($Arguments -contains 'Accept: application/vnd.github.raw+json') {
                return @{ ExitCode = 0; StdOut = 'large catalog content'; StdErr = '' }
            }
            return @{ ExitCode = 0; StdOut = $metadata; StdErr = '' }
        }

        $result = Get-AvmRepositoryFileAtRef -Repository 'Azure/Azure-Verified-Modules' -Path 'docs/static/module-indexes/v1/modules.json' -Ref 'main'
        $result.Content | Should -Be 'large catalog content'
        $result.Sha | Should -Be $fixture.Sha
        Should -Invoke Invoke-RepositorySyncProcess -Exactly 2
    }

    It 'throws when the raw fallback content does not match the reported size or blob SHA' {
        $fixture = New-FileFixture -Content 'expected content'
        $metadata = @{
            type = 'file'; path = 'docs/static/module-indexes/v1/modules.json'; sha = $fixture.Sha
            size = $fixture.Bytes.Length; encoding = 'none'; content = ''
        } | ConvertTo-Json -Depth 5
        Mock Invoke-RepositorySyncProcess {
            param($Command, $Arguments)
            if ($Arguments -contains 'Accept: application/vnd.github.raw+json') {
                return @{ ExitCode = 0; StdOut = 'corrupted content'; StdErr = '' }
            }
            return @{ ExitCode = 0; StdOut = $metadata; StdErr = '' }
        }

        { Get-AvmRepositoryFileAtRef -Repository 'Azure/Azure-Verified-Modules' -Path 'docs/static/module-indexes/v1/modules.json' -Ref 'main' } |
            Should -Throw '*size or blob SHA mismatch*'
    }

    It 'returns $null for a missing file when -AllowMissing is set' {
        Mock Invoke-RepositorySyncProcess { @{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 404: Not Found (HTTP 404)' } }
        Get-AvmRepositoryFileAtRef -Repository 'Azure/bicep-registry-modules' -Path 'avm/res/missing/module/metadata.json' -Ref 'main' -AllowMissing |
            Should -BeNullOrEmpty
    }

    It 'throws on a missing file when -AllowMissing is not set' {
        Mock Invoke-RepositorySyncProcess { @{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 404: Not Found (HTTP 404)' } }
        { Get-AvmRepositoryFileAtRef -Repository 'Azure/bicep-registry-modules' -Path 'avm/res/missing/module/metadata.json' -Ref 'main' } |
            Should -Throw
    }
}
