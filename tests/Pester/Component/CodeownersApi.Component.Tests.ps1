BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:root 'repository-management' 'bicep-codeowners-sync' 'scripts' 'lib' 'GitHubSync.ps1')
}

Describe 'CODEOWNERS JSON request serialization' -Tag Component {
    BeforeEach {
        $script:bodyPath = $null
        $script:receivedBody = $null
        $script:receivedArguments = $null
        Mock Invoke-AvmCodeownersGh {
            param($ArgumentList)
            $script:receivedArguments = $ArgumentList
            $inputIndex = [array]::IndexOf($ArgumentList, '--input')
            $script:bodyPath = $ArgumentList[$inputIndex + 1]
            $script:receivedBody = Get-Content -LiteralPath $script:bodyPath -Raw | ConvertFrom-Json
            '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
        }
    }

    It 'passes generated content as literal JSON in a file rather than shell arguments' {
        $literal = '# literal $(throw "not executable"); quote " and a backtick `'
        $body = @{ tree = @(@{ path = '.github/CODEOWNERS'; content = $literal }); base_tree = 'a' * 40 }
        $result = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/trees' -Method POST -Body $body
        $result.sha | Should -BeExactly ('b' * 40)
        $script:receivedBody.tree[0].content | Should -BeExactly $literal
        $script:receivedBody.tree[0].path | Should -BeExactly '.github/CODEOWNERS'
        ($script:receivedArguments -join ' ') | Should -Not -Match ([regex]::Escape($literal))
        Test-Path -LiteralPath $script:bodyPath | Should -BeFalse
    }

    It 'does not put large CODEOWNERS content on the Windows command line' {
        $content = 'x' * 100000
        $null = Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/trees' -Method POST `
            -Body @{ tree = @(@{ path = '.github/CODEOWNERS'; content = $content }) }
        $script:receivedBody.tree[0].content.Length | Should -Be 100000
        ($script:receivedArguments -join ' ').Length | Should -BeLessThan 2000
        Test-Path -LiteralPath $script:bodyPath | Should -BeFalse
    }

    It 'cleans the request file when the API command fails and preserves the failure' {
        Mock Invoke-AvmCodeownersGh {
            param($ArgumentList)
            $script:bodyPath = $ArgumentList[([array]::IndexOf($ArgumentList, '--input') + 1)]
            throw 'HTTP 403: denied'
        }
        { Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/trees' -Method POST `
            -Body @{ tree = @(@{ path = '.github/CODEOWNERS'; content = 'data' }) } } | Should -Throw '*HTTP 403*'
        Test-Path -LiteralPath $script:bodyPath | Should -BeFalse
    }

    It 'cleans the request file when successful HTTP returns invalid JSON' {
        Mock Invoke-AvmCodeownersGh {
            param($ArgumentList)
            $script:bodyPath = $ArgumentList[([array]::IndexOf($ArgumentList, '--input') + 1)]
            '{invalid'
        }
        { Invoke-AvmCodeownersApi -Endpoint 'repos/Azure/bicep-registry-modules/git/trees' -Method POST `
            -Body @{ tree = @(@{ path = '.github/CODEOWNERS'; content = 'data' }) } } | Should -Throw
        Test-Path -LiteralPath $script:bodyPath | Should -BeFalse
    }
}
