#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Script to validate feature backlog order
 
.DESCRIPTION 
    This script will retrieve an order backlog and iterate through items to validate precessor <-> successor relationships orhonoured in the backlog order.
    Invalid ordered items are listed.
    This script requires a PAT to be set via the AZURE_DEVOPS_EXT_PAT environment variable or passed in as -Token parameter.
    
.EXAMPLE
    ./validate_backlog_order.ps1 -Organization "https://dev.azure.com/myorg" -Project MyProject -Team "My Team"
#> 
#Requires -Version 7

param ( 
    [parameter(Mandatory=$false)][string]$OrganizationUrl=$env:AZDO_ORG_SERVICE_URL,
    [parameter(Mandatory=$false)][string]$Project,
    [parameter(Mandatory=$false)][string]$Team,
    [parameter(Mandatory=$false)][string]$Token=$env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN
) 
$apiVersion = "7.1-preview"

# Validation & Parameter processing
if (!$OrganizationUrl) {
    Write-Warning "OrganizationUrl is required. Please specify -OrganizationUrl or set the AZDO_ORG_SERVICE_URL environment variable."
    exit 1
}
$OrganizationUrl = $OrganizationUrl -replace "/$","" # Strip trailing '/'
if (!$Project) {
    Write-Warning "Project is required. Please specify Project"
    exit 1
}
if (!$Team) {
    Write-Warning "Team is required. Please specify Team"
    exit 1
}
if (!$Token) {
    Write-Warning "No access token found. Please specify -Token or set the AZURE_DEVOPS_EXT_PAT or AZDO_PERSONAL_ACCESS_TOKEN environment variable."
    exit 1
}

Write-Host "Authenticating to organization ${OrganizationUrl}..."
$Token | az devops login --organization $OrganizationUrl

Write-Host "Retrieving Feature backlog for team '${Team}' in ${OrganizationUrl}/${Project}..."
az devops invoke --org $OrganizationUrl `
                 --area work `
                 --api-version $apiVersion `
                 --route-parameters project=$Project team=$Team `
                 --resource backlogs `
                 --query-parameters backlogId=Microsoft.FeatureCategory `
                 --query workItems `
                 -o json `
                 | ConvertFrom-Json `
                 | Set-Variable workItemResponse
Write-Debug "Work items in backlog API response for team '${Team}' in ${OrganizationUrl}/${Project}:"
$workItemResponse | Format-Table | Out-String | Write-Debug

# Process response and create list of work items
Write-Verbose "Processing backlog API response and creating a list of work items for team '${Team}' in ${OrganizationUrl}/${Project}..."
$workItems = [PSObject[]]::new($workItemResponse.Length)
[int]$index = 0
foreach ($responseItem in $workItemResponse) {
    [int]$order = $index + 1
    $workItems[$index] = New-Object PSObject -Property @{
        AreaPath            = $null
        Id                  = $responseItem.target.id
        InvalidPredecessors = New-Object System.Collections.ArrayList
        InvalidOrder        = $false
        InvalidSuccessors   = New-Object System.Collections.ArrayList
        IterationPath       = $null
        Link                = "${OrganizationUrl}/${Project}/_workitems/edit/$($responseItem.target.id)"
        Order               = $order
        Parent              = $null
        Predecessors        = New-Object System.Collections.ArrayList
        Successors          = New-Object System.Collections.ArrayList
        Title               = $null
        WorkItemType        = $null
    }
    $index++
}
Write-Debug "Work items in backlog for team '${Team}' in ${OrganizationUrl}/${Project}:"
$workItems | Format-Table | Out-String | Write-Debug

Write-Host "Iterating through work items to retrieve predecessor data..."
foreach ($workItem in $workItems) {
    "{0}/{1}" -f $workItem.Order, $workItems.Length | Set-Variable progressPrefix

    $workItemId = $workItem.Id
    Write-Debug "${progressPrefix}: Retrieving predesessors for work item ${workItemId} (order:$($workItem.Order))..."
    az boards work-item show --id $workItemId `
                             --org $env:AZDO_ORG_SERVICE_URL `
                             -o json `
                             | ConvertFrom-Json `
                             | Set-Variable workItemObject

    Write-Debug "${progressPrefix}: workItemObject:"
    $workItemObject.fields | Format-List | Out-String | Write-Debug

    $workItem.AreaPath      = $workItemObject.fields."System.AreaPath"
    $workItem.IterationPath = $workItemObject.fields."System.IterationPath"
    $workItem.Parent        = $workItemObject.fields."System.Parent"
    $workItem.Title         = $workItemObject.fields."System.Title"
    $workItem.WorkItemType  = $workItemObject.fields."System.WorkItemType"
    Write-Debug "${progressPrefix}: workItem:"
    $workItem | Format-List | Out-String | Write-Debug

    $predecessorUrls = $null
    $workItemObject.relations | Where-Object -Property rel -eq "System.LinkTypes.Dependency-Reverse" `
                              | Select-Object -ExpandProperty url `
                              | Set-Variable predecessorUrls
    if ($predecessorUrls) {
        Write-Debug "${progressPrefix}: Predecessors for ${workItemId}:"
        $predecessorUrls | Write-Debug
    }

    foreach ($predecessorUrl in $predecessorUrls) {
        $predecessorId = $predecessorUrl.Split('/')[-1]
        Write-Verbose "${progressPrefix}: $predecessorId is a predecessor of $workItemId"
        $workItem.Predecessors.Add($predecessorId) | Out-Null
        $predecessor = $null
        $workItems | Where-Object -Property Id -eq $predecessorId | Set-Variable predecessor
        if ($predecessor) {
            Write-Debug "${progressPrefix}: Predecessor $predecessorId of $workItemId is also in backlog of team '${Team}'"
            $predecessor.Successors.Add($workItemId) | Out-Null

            if ($predecessor.Order -gt $workItem.Order) {
                Write-Warning "${progressPrefix}: $($PSStyle.Bold)$($PSStyle.Foreground.Red)✘$($PSStyle.Reset) Predecessor $predecessorId (order:$($predecessor.Order)) is below $workItemId (order:$($workItem.Order)) on backlog of team '${Team}'"
                $predecessor.InvalidOrder = $true
                $predecessor.InvalidSuccessors.Add($workItemId) | Out-Null
                $workItem.InvalidOrder = $true
                $workItem.InvalidPredecessors.Add($predecessorId) | Out-Null
            } else {
                Write-Information "${progressPrefix}: $($PSStyle.Bold)$($PSStyle.Foreground.Green)✔$($PSStyle.Reset) Predecessor $predecessorId (order:$($predecessor.Order)) is above $workItemId (order:$($workItem.Order)) on backlog of team '${Team}'"
            }
        } else {
            Write-Information "${progressPrefix}: Predecessor $predecessorId of $workItemId is not in backlog of team '${Team}'"
        }
    }
}

$workItems | Where-Object -Property InvalidOrder -eq $true | Set-Variable invalidOrderedWorkItems
if ($invalidOrderedWorkItems) {
    Write-Warning "Work items in incorrect order (predecessor after successor):"
    $invalidOrderedWorkItems | Format-Table -Property Order, Id, Title, InvalidPredecessors, InvalidSuccessors, AreaPath, Link
}

# Export CSV (can be imported to Excel)
New-TemporaryFile | Select-Object -ExpandProperty FullName | Set-Variable csvFileName
$csvFileName += ".csv"
$workItems | Export-Csv -Path "$csvFileName" -NoTypeInformation
Write-Host "Work item list exported to ${csvFileName}"
