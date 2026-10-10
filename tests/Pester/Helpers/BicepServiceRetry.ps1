function New-BicepServiceRetryFixture {
    param(
        [ValidateSet('SearchSku', 'SearchSemantic', 'ContainerApps', 'ContainerAppsNewCluster')]
        [string] $Kind,
        [string] $Region = 'eastus',
        [string] $SubscriptionId = '11111111-1111-1111-1111-111111111111'
    )

    $isContainer = $Kind.StartsWith('ContainerApps')
    $provider = if ($isContainer) { 'Microsoft.App/managedEnvironments' } else { 'Microsoft.Search/searchServices' }
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/retry-fixture/providers/$provider/service"
    if ($isContainer) {
        $summary = if ($Kind -eq 'ContainerApps') {
            "AKS is experiencing heavy usage in region $Region. We are working on adding new capacity. In the meantime, please consider creating new AKS clusters in a different region."
        }
        else {
            "Creating a new cluster is unavailable at this time in region $Region. To create a new cluster, we recommend using an alternate region."
        }
        $summary += ' For a list of all the Azure regions, visit https://aka.ms/aks/regions. For more details on this error, visit https://aka.ms/akscapacityheavyusage.'
        $body = [ordered]@{ code = 'AKSCapacityHeavyUsage'; details = $null; message = $summary; subcode = '' } | ConvertTo-Json -Compress
        $leaf = @{
            code = 'ManagedEnvironmentCapacityHeavyUsageError'
            message = "$summary`nStatus: 400 (Bad Request)`nErrorCode: AKSCapacityHeavyUsage`n`nContent:`n$body`n`nHeaders:`nContent-Type: application/json`n"
        }
        $node = @{ code = 'ResourceDeploymentFailure'; target = $resourceId; details = @($leaf) }
    }
    elseif ($Kind -eq 'SearchSku') {
        $leaf = @{
            code = 'ResourcesForSkuUnavailable'
            message = "The region '$Region' currently does not have enough resources available to provision services with the SKU 'standard'. Try creating the service in another region or selecting a different SKU. RequestId: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        }
        $node = $leaf
    }
    else {
        $leaf = @{
            code = 'BadRequest'
            message = "Semantic Search is not available in '$Region' region. Please refer to https://aka.ms/semanticsearchavailability for list of available regions."
        }
        $node = @{ code = 'DeploymentFailed'; details = @($leaf) }
    }
    [pscustomobject]@{
        Kind = $Kind; Region = $Region; SubscriptionId = $SubscriptionId
        Provider = $provider; ResourceId = $resourceId; Leaf = $leaf
        Response = @{ error = $node }
    }
}
