@{
    Area      = 'commands'
    Function  = 'ConvertFrom-AvmReleaseCommand'
    Scenarios = @(
        @{
            Id       = 'commands-01'
            Title    = '#Release on its own is a release command'
            Design   = 'Commands: #Release'
            Input    = @{ Body = '#Release' }
            Expected = @{
                Name     = 'Release'
                Reason   = $null
                Markdown = $null
                Error    = $null
            }
        }
        @{
            Id       = 'commands-02'
            Title    = 'Command names are case-insensitive'
            Design   = 'Commands: commands are case-insensitive'
            Input    = @{ Body = '#release' }
            Expected = @{ Name = 'Release' }
        }
        @{
            Id         = 'commands-03'
            Title      = '#Release ignores text after the command'
            Design     = 'Commands: #Release'
            Assumption = '#Release accepts and ignores trailing text on its line, so a short explanation does not cancel the command.'
            Input      = @{ Body = '#RELEASE please ship it' }
            Expected   = @{
                Name   = 'Release'
                Reason = $null
                Error  = $null
            }
        }
        @{
            Id       = 'commands-04'
            Title    = '#DoNotRelease takes its reason from the same line'
            Design   = 'Commands: #DoNotRelease <reason>'
            Input    = @{ Body = '#DoNotRelease waiting for provider fix' }
            Expected = @{
                Name   = 'DoNotRelease'
                Reason = 'waiting for provider fix'
                Error  = $null
            }
        }
        @{
            Id         = 'commands-05'
            Title      = '#DoNotRelease takes its reason from the following lines when the first line has none'
            Design     = 'Commands: #DoNotRelease <reason>'
            Assumption = 'A reason written on the lines after a bare #DoNotRelease counts as the reason.'
            Input      = @{
                Body = @'
#donotrelease

Waiting for the provider fix in
azurerm 4.2.
'@
            }
            Expected   = @{
                Name   = 'DoNotRelease'
                Reason = @'
Waiting for the provider fix in
azurerm 4.2.
'@
                Error  = $null
            }
        }
        @{
            Id         = 'commands-06'
            Title      = '#DoNotRelease without a reason is reported as an error'
            Design     = 'Commands: #DoNotRelease <reason>'
            Assumption = '#DoNotRelease requires a reason. The engine rejects the command and replies with the missing-reason error.'
            Input      = @{ Body = '#DoNotRelease   ' }
            Expected   = @{
                Name   = 'DoNotRelease'
                Reason = $null
                Error  = 'missing-reason'
            }
        }
        @{
            Id       = 'commands-07'
            Title    = 'A quoted command is not a command'
            Design   = 'Commands: ignore quoted text'
            Input    = @{ Body = '> #Release' }
            Expected = $null
        }
        @{
            Id       = 'commands-08'
            Title    = 'A command in a code span is not a command'
            Design   = 'Commands: ignore code'
            Input    = @{ Body = '`#Release`' }
            Expected = $null
        }
        @{
            Id       = 'commands-09'
            Title    = 'A command inside a backtick fence is not a command'
            Design   = 'Commands: ignore code blocks'
            Input    = @{
                Body = @'
```
#Release
```
'@
            }
            Expected = $null
        }
        @{
            Id       = 'commands-10'
            Title    = 'A command inside a tilde fence is not a command'
            Design   = 'Commands: ignore code blocks'
            Input    = @{
                Body = @'
~~~
#Release
~~~
'@
            }
            Expected = $null
        }
        @{
            Id       = 'commands-11'
            Title    = 'A command in an indented code block is not a command'
            Design   = 'Commands: ignore code blocks'
            Input    = @{ Body = '    #Release' }
            Expected = $null
        }
        @{
            Id       = 'commands-12'
            Title    = 'A command after other text is not a command'
            Design   = 'Commands: only the first non-empty line counts'
            Input    = @{
                Body = @'
Thanks for the review!
#Release
'@
            }
            Expected = $null
        }
        @{
            Id       = 'commands-13'
            Title    = 'A longer word that starts with a command name is not a command'
            Design   = 'Commands: exact command names'
            Input    = @{ Body = '#Releasefoo' }
            Expected = $null
        }
        @{
            Id       = 'commands-14'
            Title    = 'A command name followed by punctuation is not a command'
            Design   = 'Commands: exact command names'
            Input    = @{ Body = '#Release!' }
            Expected = $null
        }
        @{
            Id       = 'commands-15'
            Title    = 'An issue reference is not a command'
            Design   = 'Commands: exact command names'
            Input    = @{ Body = '#123 is fixed' }
            Expected = $null
        }
        @{
            Id       = 'commands-16'
            Title    = 'An empty comment holds no command'
            Design   = 'Commands'
            Input    = @{ Body = '' }
            Expected = $null
        }
        @{
            Id       = 'commands-17'
            Title    = 'A whitespace-only comment holds no command'
            Design   = 'Commands'
            Input    = @{ Body = '   ' }
            Expected = $null
        }
        @{
            Id       = 'commands-18'
            Title    = 'Leading blank lines and a short indent do not hide a command'
            Design   = 'Commands: the first non-empty line'
            Input    = @{
                Body = @'


  #Release
'@
            }
            Expected = @{ Name = 'Release' }
        }
        @{
            Id       = 'commands-19'
            Title    = '#ReleaseNotes takes the rest of the first line as Markdown'
            Design   = 'Commands: #ReleaseNotes'
            Input    = @{ Body = '#ReleaseNotes This release prepares the module for shared network inputs.' }
            Expected = @{
                Name     = 'ReleaseNotes'
                Markdown = 'This release prepares the module for shared network inputs.'
                Error    = $null
            }
        }
        @{
            Id       = 'commands-20'
            Title    = '#ReleaseNotes takes the following lines as Markdown'
            Design   = 'Commands: #ReleaseNotes'
            Input    = @{
                Body = @'
#ReleaseNotes

## Breaking changes

- #142 removes `subnet_id`.

'@
            }
            Expected = @{
                Name     = 'ReleaseNotes'
                Markdown = @'
## Breaking changes

- #142 removes `subnet_id`.
'@
            }
        }
        @{
            Id       = 'commands-21'
            Title    = '#ReleaseNotes joins first-line text with the following lines'
            Design   = 'Commands: #ReleaseNotes'
            Input    = @{
                Body = @'
#releasenotes First line.
Second line.
'@
            }
            Expected = @{
                Name     = 'ReleaseNotes'
                Markdown = @'
First line.
Second line.
'@
            }
        }
        @{
            Id       = 'commands-22'
            Title    = 'A bare #ReleaseNotes has empty Markdown'
            Design   = 'Commands: #ReleaseNotes'
            Input    = @{ Body = '#ReleaseNotes' }
            Expected = @{
                Name     = 'ReleaseNotes'
                Markdown = ''
            }
        }
        @{
            Id       = 'commands-23'
            Title    = 'A second command name on the first line is part of the first command'
            Design   = 'Commands: one command per comment'
            Input    = @{ Body = '#Release #DoNotRelease oops' }
            Expected = @{
                Name   = 'Release'
                Reason = $null
            }
        }
        @{
            Id       = 'commands-24'
            Title    = 'The #DoNotRelease reason is trimmed'
            Design   = 'Commands: #DoNotRelease <reason>'
            Input    = @{ Body = '#DoNotRelease    provider bug   ' }
            Expected = @{
                Name   = 'DoNotRelease'
                Reason = 'provider bug'
            }
        }
    )
}
