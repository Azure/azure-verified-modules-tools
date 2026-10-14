#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module -Name (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
    $script:gitPath = (Get-Command -Name git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1).Source
    $script:realProcess = InModuleScope 'Avm.Authoring' { ${function:Invoke-AvmProcess} }

    $gitConfig = Join-Path $TestDrive 'gitconfig'
    [System.IO.File]::WriteAllText($gitConfig, '')
    $script:gitEnvironment = @{
        GIT_CONFIG_GLOBAL     = $gitConfig
        GIT_CONFIG_NOSYSTEM   = '1'
        GIT_CONFIG_COUNT      = '0'
        GIT_CONFIG_PARAMETERS = $null
        GIT_DIR               = $null
        GIT_WORK_TREE         = $null
        GIT_COMMON_DIR        = $null
        GIT_TERMINAL_PROMPT   = '0'
        GIT_AUTHOR_NAME       = 'AVM Test'
        GIT_AUTHOR_EMAIL      = 'avm-test@example.invalid'
        GIT_COMMITTER_NAME    = 'AVM Test'
        GIT_COMMITTER_EMAIL   = 'avm-test@example.invalid'
    }
    $script:sourceDir = Join-Path $TestDrive 'source'
    & $script:realProcess -FilePath $script:gitPath `
        -ArgumentList @('init', '--quiet', '--initial-branch', 'main', $script:sourceDir) `
        -EnvVars $script:gitEnvironment | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $script:sourceDir 'payload.txt'), "managed-file fixture`n")
    & $script:realProcess -FilePath $script:gitPath `
        -ArgumentList @('-C', $script:sourceDir, 'add', 'payload.txt') `
        -EnvVars $script:gitEnvironment | Out-Null
    & $script:realProcess -FilePath $script:gitPath `
        -ArgumentList @('-C', $script:sourceDir, 'commit', '--quiet', '-m', 'Managed-file fixture') `
        -EnvVars $script:gitEnvironment | Out-Null
    & $script:realProcess -FilePath $script:gitPath `
        -ArgumentList @('-C', $script:sourceDir, 'tag', 'v1.1.2') `
        -EnvVars $script:gitEnvironment | Out-Null
    $script:sourceHead = (& $script:realProcess -FilePath $script:gitPath `
            -ArgumentList @('-C', $script:sourceDir, 'rev-parse', 'HEAD') `
            -EnvVars $script:gitEnvironment).StdOut.Trim()
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: managed-files checkout cache recovery' -Tag Component {
    BeforeEach {
        $script:savedAvmHome = [Environment]::GetEnvironmentVariable('AVM_HOME')
        $env:AVM_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $repositoryCache = [System.IO.Path]::Combine(
            $env:AVM_HOME, 'cache', 'managed-files', 'Azure_azure-verified-modules-managed-files')
        $script:cacheRoot = Join-Path $repositoryCache 'v1.1.2'
        $script:cacheMarker = Join-Path $script:cacheRoot 'stale-cache-marker'
        $script:siblingMarker = Join-Path (Join-Path $repositoryCache 'v1.1.3') 'keep'
        New-Item -ItemType Directory -Path (Join-Path $script:cacheRoot '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:siblingMarker) -Force | Out-Null
        [System.IO.File]::WriteAllText($script:cacheMarker, 'stale')
        [System.IO.File]::WriteAllText($script:siblingMarker, 'keep')

        InModuleScope 'Avm.Authoring' -Parameters @{
            Process     = $script:realProcess
            Source      = $script:sourceDir
            Environment = $script:gitEnvironment
        } {
            param($Process, $Source, $Environment)
            $script:checkoutRecoveryProcess = $Process
            $script:checkoutRecoverySource = $Source
            $script:checkoutRecoveryEnvironment = $Environment
            Mock Invoke-AvmProcess {
                $processArguments = @{} + $PesterBoundParameters
                $null = $processArguments.Remove('RetryNetworkFailure')
                $processArguments.EnvVars = $script:checkoutRecoveryEnvironment
                if ($ArgumentList[0] -eq 'clone') {
                    $cloneArguments = @($ArgumentList)
                    $cloneArguments[5] = $script:checkoutRecoverySource
                    $processArguments.ArgumentList = $cloneArguments
                }
                & $script:checkoutRecoveryProcess @processArguments
            }
            Mock Write-AvmLog { }
        }
    }

    AfterEach {
        $original = if ($null -eq $script:savedAvmHome) { [NullString]::Value } else { $script:savedAvmHome }
        [Environment]::SetEnvironmentVariable('AVM_HOME', $original)
    }

    It 'reclones only the invalid ref cache after a real Git not-a-repository failure' {
        $result = InModuleScope 'Avm.Authoring' -Parameters @{
            GitPath       = $script:gitPath
            CacheRoot     = $script:cacheRoot
            CacheMarker   = $script:cacheMarker
            SiblingMarker = $script:siblingMarker
        } {
            param($GitPath, $CacheRoot, $CacheMarker, $SiblingMarker)
            $checkout = Get-AvmManagedFilesCheckout `
                -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath

            Test-Path -LiteralPath $CacheMarker | Should -BeFalse
            (Get-Content -LiteralPath $SiblingMarker -Raw) | Should -BeExactly 'keep'
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'fetch' -and $RetryNetworkFailure
            }
            Should -Invoke Invoke-AvmProcess -Exactly -Times 0 -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'checkout'
            }
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter {
                $ArgumentList[0] -eq 'clone' -and $ArgumentList[4] -ceq 'v1.1.2' -and
                $ArgumentList[5] -ceq 'https://github.com/Azure/azure-verified-modules-managed-files.git' -and
                $ArgumentList[6] -ceq $CacheRoot -and $RetryNetworkFailure
            }
            Should -Invoke Write-AvmLog -Exactly -Times 1 -ParameterFilter { $Level -eq 'Warning' }
            return $checkout
        }

        $result | Should -BeExactly $script:cacheRoot
        (Get-Content -LiteralPath (Join-Path $result 'payload.txt') -Raw) |
            Should -BeExactly "managed-file fixture`n"
        (& $script:realProcess -FilePath $script:gitPath `
                -ArgumentList @('-C', $result, 'rev-parse', 'HEAD') `
                -EnvVars $script:gitEnvironment).StdOut.Trim() | Should -BeExactly $script:sourceHead
    }

    It 'also recovers when checkout reports that the cache is no longer a repository' {
        Remove-Item -LiteralPath $script:cacheRoot -Recurse -Force
        & $script:realProcess -FilePath $script:gitPath `
            -ArgumentList @('clone', '--quiet', '--branch', 'v1.1.2', $script:sourceDir, $script:cacheRoot) `
            -EnvVars $script:gitEnvironment | Out-Null
        [System.IO.File]::WriteAllText($script:cacheMarker, 'stale')

        InModuleScope 'Avm.Authoring' -Parameters @{
            GitPath     = $script:gitPath
            CacheMarker = $script:cacheMarker
        } {
            param($GitPath, $CacheMarker)
            Mock Invoke-AvmProcess {
                throw [AvmProcessException]::new(
                    'cached checkout failed', $FilePath, $ArgumentList, 128, '',
                    'fatal: not a git repository (or any of the parent directories): .git')
            } -ParameterFilter { $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'checkout' }

            Get-AvmManagedFilesCheckout `
                -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath | Out-Null

            Test-Path -LiteralPath $CacheMarker | Should -BeFalse
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'checkout'
            }
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
        }
    }

    It 'preserves the cache and original error for <FailureName> failures' -ForEach @(
        @{ FailureName = 'authentication'; ExitCode = 128; StandardError = 'fatal: Authentication failed' }
        @{ FailureName = 'missing remote'; ExitCode = 128; StandardError = 'fatal: repository not found' }
        @{ FailureName = 'missing ref'; ExitCode = 128; StandardError = "fatal: couldn't find remote ref v1.1.2" }
        @{ FailureName = 'network'; ExitCode = 128; StandardError = 'fatal: unable to access repository: connection failed' }
        @{ FailureName = 'ownership'; ExitCode = 128; StandardError = 'fatal: detected dubious ownership in repository' }
        @{ FailureName = 'different exit code'; ExitCode = 1; StandardError = 'fatal: not a git repository' }
        @{ FailureName = 'unrelated fatal message'; ExitCode = 128; StandardError = 'fatal: remote rejected: not a git repository' }
    ) {
        param($ExitCode, $StandardError)
        InModuleScope 'Avm.Authoring' -Parameters @{
            GitPath       = $script:gitPath
            CacheMarker   = $script:cacheMarker
            SiblingMarker = $script:siblingMarker
            ExitCode      = $ExitCode
            StandardError = $StandardError
        } {
            param($GitPath, $CacheMarker, $SiblingMarker, $ExitCode, $StandardError)
            $script:checkoutRecoveryFailure = [AvmProcessException]::new(
                'cached fetch failed', $GitPath, @(), $ExitCode, '', $StandardError)
            Mock Invoke-AvmProcess { throw $script:checkoutRecoveryFailure } -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'fetch'
            }

            $failure = {
                Get-AvmManagedFilesCheckout `
                    -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath
            } | Should -Throw -ExceptionType ([AvmProcessException]) -PassThru

            $failure.Exception | Should -Be $script:checkoutRecoveryFailure
            Test-Path -LiteralPath $CacheMarker | Should -BeTrue
            (Get-Content -LiteralPath $SiblingMarker -Raw) | Should -BeExactly 'keep'
            Should -Invoke Invoke-AvmProcess -Exactly -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
            Should -Invoke Write-AvmLog -Exactly -Times 0 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    It 'does not treat a timeout with matching message text as cache corruption' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            GitPath     = $script:gitPath
            CacheMarker = $script:cacheMarker
        } {
            param($GitPath, $CacheMarker)
            Mock Invoke-AvmProcess {
                throw [System.TimeoutException]::new('fatal: not a git repository')
            } -ParameterFilter { $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'fetch' }

            {
                Get-AvmManagedFilesCheckout `
                    -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath
            } | Should -Throw -ExceptionType ([System.TimeoutException])

            Test-Path -LiteralPath $CacheMarker | Should -BeTrue
            Should -Invoke Invoke-AvmProcess -Exactly -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
        }
    }

    It 'propagates a failed replacement clone without another cache recovery attempt' {
        InModuleScope 'Avm.Authoring' -Parameters @{
            GitPath       = $script:gitPath
            CacheMarker   = $script:cacheMarker
            SiblingMarker = $script:siblingMarker
        } {
            param($GitPath, $CacheMarker, $SiblingMarker)
            Mock Invoke-AvmProcess {
                throw [AvmProcessException]::new(
                    'replacement clone failed', $FilePath, $ArgumentList, 128, '',
                    'fatal: not a git repository')
            } -ParameterFilter { $ArgumentList[0] -eq 'clone' }

            {
                Get-AvmManagedFilesCheckout `
                    -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath
            } | Should -Throw -ExceptionType ([AvmProcessException]) -ExpectedMessage 'replacement clone failed'

            Test-Path -LiteralPath $CacheMarker | Should -BeFalse
            (Get-Content -LiteralPath $SiblingMarker -Raw) | Should -BeExactly 'keep'
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
        }
    }

    It 'reuses a healthy cache without clearing it or cloning again' {
        Remove-Item -LiteralPath $script:cacheRoot -Recurse -Force
        & $script:realProcess -FilePath $script:gitPath `
            -ArgumentList @('clone', '--quiet', '--branch', 'v1.1.2', $script:sourceDir, $script:cacheRoot) `
            -EnvVars $script:gitEnvironment | Out-Null
        [System.IO.File]::WriteAllText($script:cacheMarker, 'keep')

        InModuleScope 'Avm.Authoring' -Parameters @{
            GitPath     = $script:gitPath
            CacheRoot   = $script:cacheRoot
            CacheMarker = $script:cacheMarker
        } {
            param($GitPath, $CacheRoot, $CacheMarker)
            Get-AvmManagedFilesCheckout `
                -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath |
                Should -BeExactly $CacheRoot

            (Get-Content -LiteralPath $CacheMarker -Raw) | Should -BeExactly 'keep'
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'fetch' -and $RetryNetworkFailure
            }
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'checkout'
            }
            Should -Invoke Invoke-AvmProcess -Exactly -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'clone' }
            Should -Invoke Write-AvmLog -Exactly -Times 0 -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    It 'still clones a missing cache directly' {
        Remove-Item -LiteralPath $script:cacheRoot -Recurse -Force
        InModuleScope 'Avm.Authoring' -Parameters @{ GitPath = $script:gitPath; CacheRoot = $script:cacheRoot } {
            param($GitPath, $CacheRoot)
            Get-AvmManagedFilesCheckout `
                -Repo 'Azure/azure-verified-modules-managed-files' -Ref 'v1.1.2' -GitPath $GitPath |
                Should -BeExactly $CacheRoot

            Test-Path -LiteralPath (Join-Path $CacheRoot 'payload.txt') | Should -BeTrue
            Should -Invoke Invoke-AvmProcess -Exactly -Times 1 -ParameterFilter {
                $ArgumentList[0] -eq 'clone' -and $RetryNetworkFailure
            }
            Should -Invoke Invoke-AvmProcess -Exactly -Times 0 -ParameterFilter {
                $ArgumentList[0] -eq '-C' -and $ArgumentList[2] -eq 'fetch'
            }
        }
    }
}
