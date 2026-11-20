@{
    Area      = 'version'
    Function  = 'Get-AvmReleaseVersionPlan'
    Scenarios = @(
        @{
            Id       = 'version-01'
            Title    = 'A single patch label bumps the patch number'
            Design   = 'Selecting the version'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('patch') }
                )
            }
            Expected = @{
                Version         = '0.8.3'
                PreviousVersion = '0.8.2'
                Increment       = 'patch'
                Issues          = @()
            }
        }
        @{
            Id       = 'version-02'
            Title    = 'The highest label wins and the release gets one increment'
            Design   = 'Selecting the version: patch, minor, and patch PRs produce one minor increment, 0.8.2 to 0.9.0'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('patch') }
                    @{ Number = 11; Labels = @('minor') }
                    @{ Number = 12; Labels = @('patch') }
                )
            }
            Expected = @{
                Version   = '0.9.0'
                Increment = 'minor'
                Issues    = @()
            }
        }
        @{
            Id       = 'version-03'
            Title    = 'Several minor labels still produce one minor increment'
            Design   = 'Selecting the version: each release gets one increment, not one per PR'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('minor') }
                    @{ Number = 11; Labels = @('minor') }
                )
            }
            Expected = @{
                Version = '0.9.0'
                Issues  = @()
            }
        }
        @{
            Id       = 'version-04'
            Title    = 'A major label after 1.0.0 resets minor and patch'
            Design   = 'Selecting the version: major > minor > patch'
            Input    = @{
                CurrentVersion = '1.4.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('minor') }
                    @{ Number = 11; Labels = @('major') }
                )
            }
            Expected = @{
                Version   = '2.0.0'
                Increment = 'major'
                Issues    = @()
            }
        }
        @{
            Id       = 'version-05'
            Title    = 'A minor label after 1.0.0 resets the patch number'
            Design   = 'Selecting the version'
            Input    = @{
                CurrentVersion = '1.4.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('minor') }
                )
            }
            Expected = @{
                Version = '1.5.0'
                Issues  = @()
            }
        }
        @{
            Id       = 'version-06'
            Title    = 'A major label before 1.0.0 is rejected and no version is proposed'
            Design   = 'Selecting the version: before 1.0.0, reject major labels'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('patch') }
                    @{ Number = 12; Labels = @('major') }
                )
            }
            Expected = @{
                Version = $null
                Issues  = @(
                    @{ Code = 'major-before-1.0'; PullRequest = 12 }
                )
            }
        }
        @{
            Id       = 'version-07'
            Title    = 'A leading v on the current version is accepted'
            Design   = 'Selecting the version'
            Input    = @{
                CurrentVersion = 'v0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('minor') }
                )
            }
            Expected = @{
                Version         = '0.9.0'
                PreviousVersion = '0.8.2'
            }
        }
        @{
            Id       = 'version-08'
            Title    = 'A release-triggering PR without a version label blocks the version'
            Design   = 'The release-metadata check: block publication rather than guess when a release-triggering PR has a missing label'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('patch') }
                    @{ Number = 11; Labels = @() }
                )
            }
            Expected = @{
                Version = $null
                Issues  = @(
                    @{ Code = 'missing-label'; PullRequest = 11 }
                )
            }
        }
        @{
            Id       = 'version-09'
            Title    = 'A PR with two version labels blocks the version'
            Design   = 'The release-metadata check: one label only'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('patch', 'minor') }
                )
            }
            Expected = @{
                Version = $null
                Issues  = @(
                    @{ Code = 'conflicting-labels'; PullRequest = 10 }
                )
            }
        }
        @{
            Id       = 'version-10'
            Title    = 'Label names are case-insensitive and other labels are ignored'
            Design   = 'Selecting the version'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('Minor', 'documentation') }
                )
            }
            Expected = @{
                Version = '0.9.0'
                Issues  = @()
            }
        }
        @{
            Id         = 'version-11'
            Title      = 'No published version blocks the version calculation'
            Design     = 'Selecting the version'
            Assumption = 'A repository with no published version blocks publication. Phase 6 onboarding handles first releases.'
            Input      = @{
                CurrentVersion = $null
                PullRequests   = @(
                    @{ Number = 10; Labels = @('minor') }
                )
            }
            Expected   = @{
                Version         = $null
                PreviousVersion = $null
                Issues          = @(
                    @{ Code = 'missing-base-version'; PullRequest = $null }
                )
            }
        }
        @{
            Id       = 'version-12'
            Title    = 'A malformed current version blocks the version calculation'
            Design   = 'Selecting the version'
            Input    = @{
                CurrentVersion = '1.2'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('patch') }
                )
            }
            Expected = @{
                Version = $null
                Issues  = @(
                    @{ Code = 'invalid-base-version'; PullRequest = $null }
                )
            }
        }
        @{
            Id       = 'version-13'
            Title    = 'No release-triggering PRs means nothing to release'
            Design   = 'Which PRs trigger a release'
            Input    = @{
                CurrentVersion = '0.8.2'
                PullRequests   = @()
            }
            Expected = @{
                Version   = $null
                Increment = $null
                Issues    = @(
                    @{ Code = 'nothing-to-release'; PullRequest = $null }
                )
            }
        }
        @{
            Id       = 'version-14'
            Title    = 'A minor label at 0.9.x moves to 0.10.0, never to 1.0.0'
            Design   = 'Selecting the version: promotion to 1.0.0 follows the existing approval process'
            Input    = @{
                CurrentVersion = '0.9.4'
                PullRequests   = @(
                    @{ Number = 10; Labels = @('minor') }
                )
            }
            Expected = @{
                Version = '0.10.0'
                Issues  = @()
            }
        }
    )
}
