function Test-AvmBicepNestedDeploymentReadFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)] [string] $DeploymentId,
        [Parameter(Mandatory)] [object] $DefaultProfile
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    if ($ErrorRecord.CategoryInfo.Category -in @('AuthenticationError', 'PermissionDenied', 'SecurityError', 'OperationStopped') -or
        (Get-AvmBicepDeploymentErrorKind -ErrorRecord $ErrorRecord) -ne 'Other' -or
        $DeploymentId -notmatch '\A/subscriptions/(?<subscription>[0-9a-f-]{36})/providers/Microsoft\.Resources/deployments/(?<name>[a-z0-9_.()-]+)\z') {
        return $false
    }
    $rootName = $Matches.name
    $subscription = [guid]::Empty
    if (-not [guid]::TryParseExact($Matches.subscription, 'D', [ref]$subscription) -or $subscription -eq [guid]::Empty) { return $false }
    $selectedSubscription = Get-AvmPropertyValue -InputObject $DefaultProfile -Name 'Subscription' -NoEnumerate
    $selectedId = Get-AvmPropertyValue -InputObject $selectedSubscription -Name 'Id' -NoEnumerate
    $profileSubscription = [guid]::Empty
    if ($selectedId -isnot [string] -or -not [guid]::TryParseExact($selectedId, 'D', [ref]$profileSubscription) -or
        $profileSubscription -ne $subscription) { return $false }
    $environment = Get-AvmPropertyValue -InputObject $DefaultProfile -Name 'Environment' -NoEnumerate
    $endpointText = Get-AvmPropertyValue -InputObject $environment -Name 'ResourceManagerUrl' -NoEnumerate
    $endpoint = $null
    if ($endpointText -isnot [string] -or -not [uri]::TryCreate($endpointText, [UriKind]::Absolute, [ref]$endpoint) -or
        $endpoint.Scheme -ne 'https' -or $endpoint.UserInfo -or $endpoint.Fragment -or $endpoint.Query -or
        $endpoint.AbsolutePath -ne '/') { return $false }

    $found = $false
    $visited = [System.Collections.Generic.HashSet[System.Exception]]::new()
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if (-not $visited.Add($exception) -or $visited.Count -gt 100 -or
            $exception -is [System.UnauthorizedAccessException] -or $exception -is [System.OperationCanceledException] -or
            $exception -is [System.Security.Authentication.AuthenticationException] -or
            $exception -is [System.Security.SecurityException]) { return $false }
        if ($exception -is [System.AggregateException]) {
            if ($exception.InnerExceptions.Count -ne 1) { return $false }
            $exception = $exception.InnerExceptions[0]
            continue
        }
        $status = Get-AvmPropertyValue -InputObject $exception -Name 'StatusCode' -NoEnumerate
        if ($null -ne $status -and (($status -isnot [int] -and $status -isnot [System.Net.HttpStatusCode]) -or $status -ne 404)) {
            return $false
        }
        $response = Get-AvmPropertyValue -InputObject $exception -Name 'Response' -NoEnumerate
        $request = Get-AvmPropertyValue -InputObject $exception -Name 'Request' -NoEnumerate
        if ($null -ne $response -or $null -ne $request) {
            if ($found -or $request -is [System.Collections.IList]) { return $false }
            $method = Get-AvmPropertyValue -InputObject $request -Name 'Method' -NoEnumerate
            $uriText = Get-AvmPropertyValue -InputObject $request -Name 'RequestUri' -NoEnumerate
            $uri = $null
            if (($method -isnot [string] -and $method -isnot [System.Net.Http.HttpMethod]) -or
                $method.ToString() -cne 'GET' -or ($uriText -isnot [string] -and $uriText -isnot [uri]) -or
                -not [uri]::TryCreate([string]$uriText, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or $uri.Authority -ine $endpoint.Authority -or $uri.UserInfo -or $uri.Fragment -or
                $uri.Query -cnotmatch '\A\?api-version=[0-9]{4}-[0-9]{2}-[0-9]{2}\z' -or
                $uri.AbsolutePath -notmatch '\A/subscriptions/(?<subscription>[0-9a-f-]{36})/resourceGroups/[a-z0-9_.()-]+/providers/Microsoft\.Resources/deployments/(?<name>[a-z0-9_.()-]+)/operations\z') {
                return $false
            }
            $nestedName = $Matches.name
            $nestedSubscription = [guid]::Empty
            if (-not [guid]::TryParseExact($Matches.subscription, 'D', [ref]$nestedSubscription) -or
                $nestedSubscription -ne $subscription -or $nestedName -ieq $rootName) { return $false }
            $message = "Deployment '$nestedName' could not be found."
            $body = Get-AvmPropertyValue -InputObject $exception -Name 'Body' -NoEnumerate
            $code = Get-AvmPropertyValue -InputObject $body -Name 'Code' -NoEnumerate
            $bodyMessage = Get-AvmPropertyValue -InputObject $body -Name 'Message' -NoEnumerate
            if ($code -isnot [string] -or $code -cne 'DeploymentNotFound' -or
                $bodyMessage -isnot [string] -or $bodyMessage -cne $message) { return $false }
            try { $document = ConvertFrom-AvmBicepRestResponse -Response $response -Activity 'Nested operation read' -AllowedStatus @(404) }
            catch [AvmProcessException] { return $false }
            if ($document.psbase.Count -ne 1 -or @($document.psbase.Keys) -cnotcontains 'error' -or
                $document['error'] -isnot [System.Collections.IDictionary]) { return $false }
            $errorBody = $document['error']
            if (@($errorBody.psbase.Keys | Where-Object { $_ -cnotin @('code', 'message', 'target') }).Count -gt 0 -or
                $errorBody['code'] -isnot [string] -or $errorBody['code'] -cne 'DeploymentNotFound' -or
                $errorBody['message'] -isnot [string] -or $errorBody['message'] -cne $message -or
                ($errorBody.Contains('target') -and ($errorBody['target'] -isnot [string] -or
                    $errorBody['target'] -cne $uri.AbsolutePath.Substring(0, $uri.AbsolutePath.Length - '/operations'.Length)))) { return $false }
            $found = $true
        }
        $next = $exception.InnerException
        if ($exception -is [System.Management.Automation.RuntimeException] -and $null -ne $exception.ErrorRecord) {
            if ($exception.ErrorRecord.CategoryInfo.Category -in @('AuthenticationError', 'PermissionDenied', 'SecurityError', 'OperationStopped')) {
                return $false
            }
            $recordException = $exception.ErrorRecord.Exception
            if (-not [object]::ReferenceEquals($recordException, $exception)) {
                if ($null -ne $next -and -not [object]::ReferenceEquals($next, $recordException)) { return $false }
                $next = $recordException
            }
        }
        $exception = $next
    }
    return $found
}
