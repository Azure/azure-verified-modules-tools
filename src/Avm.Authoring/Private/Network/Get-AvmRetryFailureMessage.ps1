function Get-AvmRetryFailureMessage {
    <#
    .SYNOPSIS
        Format an exhausted transient network failure for human-readable output.
    .DESCRIPTION
        Reduces low-level transport diagnostics to a short cause while preserving
        the original error for verbose output and programmatic callers.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Activity,
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [int] $Attempts
    )

    Set-StrictMode -Version 3.0

    $detail = $ErrorRecord.Exception.Message -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '\s+', ' '
    $cause = switch -Regex ($detail) {
        '(?i)could not resolve host|name resolution|no such host|nodename nor servname' {
            'the remote service name could not be resolved'
            break
        }
        '(?i)ssl|tls|schannel|handshake' {
            'a secure connection to the remote service could not be established'
            break
        }
        '(?i)timed? ?out|timeout|deadline exceeded' {
            'the connection to the remote service timed out'
            break
        }
        '(?i)connection reset|connection closed|recv failure|send failure|connection refused|no route to host' {
            'the network connection to the remote service was interrupted'
            break
        }
        '(?i)\b429\b|too many requests|rate limit' {
            'the remote service temporarily limited requests'
            break
        }
        '(?i)\b50[0234]\b|service unavailable|bad gateway|gateway timeout' {
            'the remote service was temporarily unavailable'
            break
        }
        default {
            'a temporary network or remote service failure occurred'
        }
    }

    return '{0} could not complete after {1} attempts because {2}. Check your network connection and the service status, then retry. Run the command with -Verbose for technical details.' -f `
        $Activity, $Attempts, $cause
}
