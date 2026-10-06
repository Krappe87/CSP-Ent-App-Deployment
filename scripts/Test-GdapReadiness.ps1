#Requires -Version 7.2
<#
.SYNOPSIS
    Pre-flight check: which customers' GDAP relationships allow the automated deployment?

.DESCRIPTION
    For each active GDAP relationship, this checks whether Cloud Application Administrator or
    Application Administrator is:
      (a) included in the relationship, and
      (b) actually assigned to one of your security groups (an active access assignment).
    Microsoft requires both before the Partner Center consent API will work, and both are needed to
    create the enterprise app and grant consent. Your own user must also be a member of that group;
    the group IDs are listed so you can check.

    Nothing is changed. Results go to the console and a CSV in reports/.

.EXAMPLE
    ./Test-GdapReadiness.ps1
#>
[CmdletBinding()]
param(
    [string]$DeployerConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/deployer.json'),
    [string]$ReportPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "reports/gdap-readiness-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"),
    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PartnerAppDeploy.psm1') -Force

$roleNames = @{
    '158c047a-c907-4556-b7ef-446551a6b5f7' = 'Cloud Application Administrator'
    '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
    '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
    'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
}
$consentRoleIds = @('158c047a-c907-4556-b7ef-446551a6b5f7', '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3')
$globalAdminId  = '62e90394-69f5-4237-9190-012177145e10'

$deployer = Import-DeployerConfig -Path $DeployerConfigPath
$null = Connect-Deployer -PartnerTenantId $deployer.partnerTenantId -ClientId $deployer.clientId -UseDeviceCode:$UseDeviceCode
$partnerTenantId = (Get-DeployerSession).PartnerTenantId

Write-Host 'Reading GDAP relationships...' -ForegroundColor Cyan
$relationships = @(Get-GraphCollection -TenantId $partnerTenantId -Path '/tenantRelationships/delegatedAdminRelationships' |
        Where-Object status -EQ 'active')

$rows = foreach ($relationship in $relationships) {
    $assignments = @(Get-GraphCollection -TenantId $partnerTenantId -Path "/tenantRelationships/delegatedAdminRelationships/$($relationship.id)/accessAssignments" |
            Where-Object status -EQ 'active')

    $inRelationship = @($relationship.accessDetails.unifiedRoles.roleDefinitionId)
    $assigned       = @($assignments.accessDetails.unifiedRoles.roleDefinitionId)
    $consentInRel   = @($inRelationship | Where-Object { $_ -in $consentRoleIds })
    $consentAssigned = @($assigned | Where-Object { $_ -in $consentRoleIds })
    $consentGroups  = @($assignments |
            Where-Object { @($_.accessDetails.unifiedRoles.roleDefinitionId | Where-Object { $_ -in $consentRoleIds }).Count } |
            ForEach-Object { $_.accessContainer.accessContainerId })

    $status = if ($consentAssigned.Count) { 'Ready' }
    elseif ($consentInRel.Count) { 'Role in relationship but not assigned to a group' }
    elseif ($globalAdminId -in $assigned) { 'Global Admin only (not on Microsoft''s confirmed list - test it)' }
    else { 'Needs Cloud Application Administrator' }

    [pscustomobject]@{
        CustomerName      = $relationship.customer.displayName
        TenantId          = $relationship.customer.tenantId
        Relationship      = $relationship.displayName
        EndsUtc           = $relationship.endDateTime
        Status            = $status
        ConsentRoles      = ($consentInRel | ForEach-Object { $roleNames[$_] }) -join '; '
        AssignedToGroups  = $consentGroups -join ' '
        GlobalAdminInRel  = $globalAdminId -in $inRelationship
    }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) | Out-Null
$rows | Sort-Object CustomerName | Export-Csv -Path $ReportPath -NoTypeInformation

# One line per customer: the best status across all of its active relationships.
$rank = @{ 'Ready' = 0 }
$perCustomer = $rows | Group-Object TenantId | ForEach-Object {
    $best = $_.Group | Sort-Object { $rank[$_.Status] ?? 1 }, Status | Select-Object -First 1
    [pscustomobject]@{ Customer = $best.CustomerName; TenantId = $best.TenantId; Status = $best.Status; Ends = $best.EndsUtc }
} | Sort-Object Customer

$perCustomer | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$ready = @($perCustomer | Where-Object Status -EQ 'Ready').Count
Write-Host "$ready of $(@($perCustomer).Count) customers are ready." -ForegroundColor ($ready -eq @($perCustomer).Count ? 'Green' : 'Yellow')
Write-Host "Details (including group IDs): $ReportPath"
Write-Host 'Your user must be a member of one of the listed groups. For customers that are not ready, see docs/SETUP.md step 1.'
