@{
    Area      = 'authorization'
    Function  = 'Test-AvmReleaseActorAuthorized'
    Scenarios = @(
        @{
            Id       = 'authorization-01'
            Title    = 'A user listed in metadata.json owners is authorised'
            Design   = 'Authorisation and security: owners listed in metadata.json'
            Input    = @{
                Actor      = 'alice'
                Owners     = @('alice', '@Azure/example-owners')
                ActorTeams = @()
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized   = $true
                Reason       = 'owner'
                MatchedEntry = 'alice'
            }
        }
        @{
            Id       = 'authorization-02'
            Title    = 'An owner entry with a leading @ matches the login'
            Design   = 'Authorisation and security: owners listed in metadata.json'
            Input    = @{
                Actor      = 'ALICE'
                Owners     = @('@alice')
                ActorTeams = @()
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized   = $true
                Reason       = 'owner'
                MatchedEntry = '@alice'
            }
        }
        @{
            Id       = 'authorization-03'
            Title    = 'A member of an owner team is authorised'
            Design   = 'Authorisation and security: a member of a team listed in metadata.json'
            Input    = @{
                Actor      = 'dave'
                Owners     = @('alice', '@Azure/example-owners')
                ActorTeams = @('Azure/example-owners')
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized   = $true
                Reason       = 'owner-team'
                MatchedEntry = '@Azure/example-owners'
            }
        }
        @{
            Id       = 'authorization-04'
            Title    = 'A member of the core AVM team is authorised'
            Design   = 'Authorisation and security: a member of the core AVM team'
            Input    = @{
                Actor      = 'carol'
                Owners     = @('alice', '@Azure/example-owners')
                ActorTeams = @('Azure/azure-verified-modules-engineering-owners')
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized   = $true
                Reason       = 'core-team'
                MatchedEntry = 'Azure/azure-verified-modules-engineering-owners'
            }
        }
        @{
            Id       = 'authorization-05'
            Title    = 'The core team is configurable'
            Design   = 'Authorisation and security: the core team must be configurable'
            Input    = @{
                Actor      = 'frank'
                Owners     = @('alice')
                ActorTeams = @('Azure/avm-release-admins')
                CoreTeam   = '@Azure/avm-release-admins'
            }
            Expected = @{
                Authorized   = $true
                Reason       = 'core-team'
                MatchedEntry = 'Azure/avm-release-admins'
            }
        }
        @{
            Id       = 'authorization-06'
            Title    = 'A member of the default core team is not authorised after the core team changes'
            Design   = 'Authorisation and security: the core team must be configurable'
            Input    = @{
                Actor      = 'carol'
                Owners     = @('alice')
                ActorTeams = @('Azure/azure-verified-modules-engineering-owners')
                CoreTeam   = 'Azure/avm-release-admins'
            }
            Expected = @{
                Authorized   = $false
                Reason       = 'not-owner'
                MatchedEntry = $null
            }
        }
        @{
            Id       = 'authorization-07'
            Title    = 'Membership of an unrelated team is not enough'
            Design   = 'Authorisation and security: write access alone does not authorise'
            Input    = @{
                Actor      = 'erin'
                Owners     = @('alice', '@Azure/example-owners')
                ActorTeams = @('Azure/azure-verified-modules-module-contributors')
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized = $false
                Reason     = 'not-owner'
            }
        }
        @{
            Id         = 'authorization-08'
            Title      = 'A bot is never authorised, even when listed as an owner'
            Design     = 'Authorisation and security'
            Assumption = 'Bot accounts never act for a release, so bot comments and bot labels never count as owner decisions.'
            Input      = @{
                Actor      = 'github-actions[bot]'
                Owners     = @('github-actions[bot]')
                ActorTeams = @()
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected   = @{
                Authorized = $false
                Reason     = 'bot'
            }
        }
        @{
            Id         = 'authorization-09'
            Title      = 'Unknown owners leave only the core team authorised'
            Design     = 'Authorisation and security'
            Assumption = 'When metadata.json owners cannot be read, only the core team can act.'
            Input      = @{
                Actor      = 'carol'
                Owners     = $null
                ActorTeams = @('Azure/azure-verified-modules-engineering-owners')
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected   = @{
                Authorized = $true
                Reason     = 'core-team'
            }
        }
        @{
            Id       = 'authorization-10'
            Title    = 'Unknown owners reject a usual owner'
            Design   = 'Authorisation and security'
            Input    = @{
                Actor      = 'alice'
                Owners     = $null
                ActorTeams = @()
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized = $false
                Reason     = 'not-owner'
            }
        }
        @{
            Id       = 'authorization-11'
            Title    = 'A missing actor is not authorised'
            Design   = 'Authorisation and security'
            Input    = @{
                Actor      = ''
                Owners     = @('alice')
                ActorTeams = @()
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized = $false
                Reason     = 'missing-actor'
            }
        }
        @{
            Id       = 'authorization-12'
            Title    = 'A malformed core team is an error'
            Design   = 'Authorisation and security: the core team is an org/team slug'
            Input    = @{
                Actor      = 'alice'
                Owners     = @('alice')
                ActorTeams = @()
                CoreTeam   = 'not-a-slug'
            }
            Throws   = "CoreTeam 'not-a-slug' must be an 'org/team' slug"
        }
        @{
            Id       = 'authorization-13'
            Title    = 'Team matching is case-insensitive'
            Design   = 'Authorisation and security'
            Input    = @{
                Actor      = 'dave'
                Owners     = @('@azure/Example-Owners')
                ActorTeams = @('Azure/example-owners')
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized   = $true
                Reason       = 'owner-team'
                MatchedEntry = '@azure/Example-Owners'
            }
        }
        @{
            Id       = 'authorization-14'
            Title    = 'A login that equals a team name does not match the team'
            Design   = 'Authorisation and security'
            Input    = @{
                Actor      = 'example-owners'
                Owners     = @('@Azure/example-owners')
                ActorTeams = @()
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized = $false
                Reason     = 'not-owner'
            }
        }
        @{
            Id       = 'authorization-15'
            Title    = 'A team with the same name in another organisation does not match'
            Design   = 'Authorisation and security'
            Input    = @{
                Actor      = 'mallory'
                Owners     = @('@Azure/example-owners')
                ActorTeams = @('Contoso/example-owners')
                CoreTeam   = 'Azure/azure-verified-modules-engineering-owners'
            }
            Expected = @{
                Authorized = $false
                Reason     = 'not-owner'
            }
        }
    )
}
