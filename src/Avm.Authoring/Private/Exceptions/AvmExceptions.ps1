#Requires -Version 7.4

# Typed exception classes per spec section 14. Loaded by Avm.Authoring.psm1
# alongside every other Private/ file via dot-sourcing. PowerShell parses
# 'class' blocks at dot-source time so the type is visible to subsequent
# Private/ and Public/ files via the type accelerator and via
# '[Avm.Errors.AvmToolException]::new(...)'.
#
# The base class derives from System.Exception so that our own throws look the
# same as framework exceptions to PowerShell's exception machinery and to
# Pester's -ExceptionType assertions.

class AvmException : System.Exception {
    [string] $Code

    AvmException([string] $message) : base($message) {
        $this.Code = 'AVM0000'
    }

    AvmException([string] $message, [string] $code) : base($message) {
        $this.Code = $code
    }

    AvmException([string] $message, [Exception] $innerException) : base($message, $innerException) {
        $this.Code = 'AVM0000'
    }

    AvmException([string] $message, [string] $code, [Exception] $innerException) : base($message, $innerException) {
        $this.Code = $code
    }
}

# Bad config, missing required env var, invalid manifest.
class AvmConfigurationException : AvmException {
    AvmConfigurationException([string] $message) : base($message, 'AVM1001') {}
    AvmConfigurationException([string] $message, [Exception] $innerException) : base($message, 'AVM1001', $innerException) {}
}

# A verb that does not apply to the resolved ecosystem, or is not implemented
# for it yet. Distinct from AvmConfigurationException - which means the repo is
# misconfigured and someone must fix it - so the gauntlets can skip the former
# and fail the latter. Derives from AvmConfigurationException so existing
# catches and the CLI's exit-code handling keep working unchanged.
class AvmNotSupportedException : AvmConfigurationException {
    AvmNotSupportedException([string] $message) : base($message) {}
}

# Tool resolver / install / SHA256 mismatch / archive issues.
class AvmToolException : AvmException {
    AvmToolException([string] $message) : base($message, 'AVM1010') {}
    AvmToolException([string] $message, [string] $code) : base($message, $code) {}
    AvmToolException([string] $message, [Exception] $innerException) : base($message, 'AVM1010', $innerException) {}
    AvmToolException([string] $message, [string] $code, [Exception] $innerException) : base($message, $code, $innerException) {}
}

# Subprocess exited non-zero or could not be started. Carries captured streams.
class AvmProcessException : AvmException {
    [string] $FileName
    [string[]] $ArgumentList
    [int] $ExitCode
    [string] $StdOut
    [string] $StdErr

    AvmProcessException([string] $message) : base($message, 'AVM1020') {}

    AvmProcessException(
        [string] $message,
        [string] $fileName,
        [string[]] $argumentList,
        [int] $exitCode,
        [string] $stdOut,
        [string] $stdErr
    ) : base($message, 'AVM1020') {
        $this.FileName = $fileName
        $this.ArgumentList = $argumentList
        $this.ExitCode = $exitCode
        $this.StdOut = $stdOut
        $this.StdErr = $stdErr
    }
}

# Repo context resolver couldn't classify the path.
class AvmContextException : AvmException {
    AvmContextException([string] $message) : base($message, 'AVM1030') {}
    AvmContextException([string] $message, [Exception] $innerException) : base($message, 'AVM1030', $innerException) {}
}

# A dispatched avm command completed with Status 'fail' or 'error'. Thrown at
# the public dispatch boundary (Invoke-Avm) so the hosting process exits
# non-zero and wrapping git hooks / CI steps cannot pass silently. Carries the
# structured engine result so callers that catch it keep full diagnostics.
class AvmCommandException : AvmException {
    [string] $Verb
    [string] $CommandStatus
    [object] $Result

    AvmCommandException([string] $verb, [string] $commandStatus, [object] $result) : base(
        "avm $verb reported Status '$commandStatus'.", 'AVM1040') {
        $this.Verb = $verb
        $this.CommandStatus = $commandStatus
        $this.Result = $result
    }

    AvmCommandException([string] $verb, [string] $commandStatus, [object] $result, [string] $detail) : base(
        $(if ([string]::IsNullOrWhiteSpace($detail)) {
                "avm $verb reported Status '$commandStatus'."
            }
            else {
                "avm $verb reported Status '$commandStatus'. $detail"
            }), 'AVM1040') {
        $this.Verb = $verb
        $this.CommandStatus = $commandStatus
        $this.Result = $result
    }
}
