#Requires -Version 7.2
<#
.SYNOPSIS
    Builds an app profile (config/apps/<name>.json): a multi-tenant app's ID plus the permissions to
    consent for it in every tenant. Create one profile per app you want to deploy.

.DESCRIPTION
    Three ways to build a profile:

      -LoginUrl            Paste the Microsoft sign-in URL the vendor's app sends you to after you click its
                           "Sign in with Microsoft" button. It contains the app's client_id and the scopes
                           it asks for. No tenant access is needed.

      -ReferenceTenantId   Read the app and its granted permissions from a tenant where consent has
                           already been accepted (your own tenant or any customer's). This is the most
                           accurate option, because it copies exactly what a Global Admin approved.

      -AppId -GraphScope   Write the profile by hand.

    The result always sets userAssignmentRequired = false, so every user in each tenant can use the app.
    Edit the JSON afterwards if you want something different.

.EXAMPLE
    ./New-TargetAppProfile.ps1 -DisplayName 'Contoso Portal' -LoginUrl 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=...&scope=...'

.EXAMPLE
    ./New-TargetAppProfile.ps1 -ReferenceTenantId 11111111-2222-3333-4444-555555555555 -DisplayName 'Contoso'

.EXAMPLE
    ./New-TargetAppProfile.ps1 -DisplayName 'Contoso Portal' -AppId 99999999-8888-7777-6666-555555555555 -GraphScope openid, profile, email, User.Read
#>
[CmdletBinding(DefaultParameterSetName = 'LoginUrl')]
param(
    [Parameter(Mandatory, ParameterSetName = 'LoginUrl')]
    [string]$LoginUrl,

    [Parameter(Mandatory, ParameterSetName = 'Reference')]
    [string]$ReferenceTenantId,

    [Parameter(ParameterSetName = 'Reference')]
    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [string]$AppId,

    # LoginUrl/Manual: the friendly name to store (also used for the file name).
    # Reference: text to search the tenant's enterprise apps for, when -AppId isn't given.
    [Parameter(Mandatory, ParameterSetName = 'LoginUrl')]
    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [Parameter(ParameterSetName = 'Reference')]
    [string]$DisplayName,

    [Parameter(ParameterSetName = 'Manual')]
    [string[]]$GraphScope = @('openid', 'profile', 'email', 'User.Read'),

    # Defaults to config/apps/<display-name>.json
    [string]$OutputPath,
    [string]$DeployerConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/deployer.json'),
    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PartnerAppDeploy.psm1') -Force

$GraphAppId = '00000003-0000-0000-c000-000000000000'

function New-GraphDelegatedEntry([string[]]$Scopes) {
    [ordered]@{ resourceAppId = $GraphAppId; resourceName = 'Microsoft Graph'; scopes = @($Scopes) }
}

function Get-ProfileFromLoginUrl([string]$Url) {
    $query = ConvertFrom-QueryString ($Url -replace '^[^?]*\?', '')
    $clientId = $query.client_id
    $scopeText = $query.scope
    $resource = $query.resource
    $redirect = $query.redirect_uri

    # The parameters can arrive URL-encoded inside another URL; fall back to searching a decoded copy.
    if (-not $clientId) {
        $decoded = [uri]::UnescapeDataString([uri]::UnescapeDataString($Url))
        if ($decoded -match '[?&]client_id=([0-9a-fA-F-]{36})') { $clientId = $Matches[1] }
        if ($decoded -match '[?&]scope=([^&]+)') { $scopeText = $Matches[1].Replace('+', ' ') }
        if ($decoded -match '[?&]resource=([^&]+)') { $resource = $Matches[1] }
        if ($decoded -match '[?&]redirect_uri=([^&]+)') { $redirect = $Matches[1] }
    }
    if (-not (Test-Guid $clientId)) {
        throw 'No client_id found in that URL. Copy the address bar as soon as the Microsoft sign-in page appears (or grab the /authorize request in browser dev tools, Network tab).'
    }

    $graphScopes = [Collections.Generic.List[string]]::new()
    $otherScopes = @()
    $usesDefault = [bool]$resource
    foreach ($scope in ($scopeText -split '\s+' | Where-Object { $_ })) {
        if ($scope -match '^(https://graph\.microsoft\.com|00000003-0000-0000-c000-000000000000)/(.+)$') { $scope = $Matches[2] }
        elseif ($scope -match '^[a-z]+://|/') { $otherScopes += $scope; continue }
        if ($scope -eq '.default') { $usesDefault = $true; continue }
        if ($scope -notin $graphScopes) { $graphScopes.Add($scope) }
    }

    if ($usesDefault) {
        throw "client_id is $clientId, but the app asks for its pre-registered permissions (.default / resource=), so the URL doesn't list them. Use -ReferenceTenantId to read them from a tenant that already consented, or use -AppId $clientId -GraphScope <the permissions shown on the consent screen>."
    }
    if ($otherScopes) {
        throw "client_id is $clientId, but it also requests non-Graph permissions ($($otherScopes -join ', ')). Use -ReferenceTenantId so the exact APIs are captured."
    }
    if ($graphScopes.Count -eq 0) {
        throw "client_id is $clientId, but no scopes were found in the URL. Use -ReferenceTenantId or -AppId/-GraphScope."
    }

    [ordered]@{
        displayName            = $DisplayName
        appId                  = $clientId
        delegatedPermissions   = @(New-GraphDelegatedEntry $graphScopes)
        applicationPermissions = @()
        userAssignmentRequired = $false
        source                 = "Login URL (redirect_uri: $redirect)"
        generatedUtc           = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-ProfileFromReferenceTenant {
    $deployer = Import-DeployerConfig -Path $DeployerConfigPath
    $null = Connect-Deployer -PartnerTenantId $deployer.partnerTenantId -ClientId $deployer.clientId -UseDeviceCode:$UseDeviceCode
    $tenantId = $ReferenceTenantId
    if (-not (Test-Guid $tenantId)) { throw '-ReferenceTenantId must be the tenant ID (GUID).' }

    if ($tenantId -ne (Get-DeployerSession).PartnerTenantId) {
        Write-Host 'Making sure the deployer app is consented in the reference tenant...'
        $consent = Grant-DeployerConsent -CustomerTenantId $tenantId -GraphScopes $deployer.customerGraphScopes
        $null = Wait-DeployerTenantAccess -TenantId $tenantId -RequiredScopes @('Application.ReadWrite.All') -Attempts ($consent -eq 'Granted' ? 9 : 1)
    }

    if ($AppId) {
        $sp = Get-ServicePrincipalByAppId -TenantId $tenantId -AppId $AppId
        if (-not $sp) { throw "No enterprise app with appId $AppId exists in tenant $tenantId." }
    } else {
        if (-not $DisplayName) { throw 'Pass -AppId, or -DisplayName with text to search the reference tenant''s enterprise apps for.' }
        $search = $DisplayName
        $found = @(Get-GraphCollection -TenantId $tenantId -Headers @{ ConsistencyLevel = 'eventual' } `
                -Path "/servicePrincipals?`$search=`"displayName:$search`"&`$select=id,appId,displayName,publisherName,appRoleAssignmentRequired")
        if ($found.Count -eq 0) { throw "No enterprise app matching '$search' in tenant $tenantId. Pass -AppId or a different -DisplayName." }
        if ($found.Count -gt 1) {
            $found | Format-Table displayName, appId, publisherName -AutoSize | Out-String | Write-Host
            throw 'More than one enterprise app matched. Run again with -AppId set to the right one from the table above.'
        }
        $sp = $found[0]
    }
    Write-Host "Found '$($sp.displayName)' (appId $($sp.appId))" -ForegroundColor Green

    $grants = @(Get-GraphCollection -TenantId $tenantId -Path "/oauth2PermissionGrants?`$filter=clientId eq '$($sp.id)'")
    if ($grants.Count -eq 0) { Write-Warning 'This app has no permission grants in the reference tenant. Consent may never have been accepted there.' }
    $delegated = foreach ($group in ($grants | Group-Object resourceId)) {
        $resource = Invoke-Graph -TenantId $tenantId -Path "/servicePrincipals/$($group.Name)?`$select=appId,displayName"
        $tenantWide = @($group.Group | Where-Object consentType -EQ 'AllPrincipals')
        if ($tenantWide.Count -eq 0) {
            Write-Warning "Only individual user consents exist for $($resource.displayName). Using the combined scopes of those users."
            $tenantWide = $group.Group
        }
        [ordered]@{
            resourceAppId = $resource.appId
            resourceName  = $resource.displayName
            scopes        = @($tenantWide.scope -split ' ' | Where-Object { $_ } | Sort-Object -Unique)
        }
    }

    $assignments = @(Get-GraphCollection -TenantId $tenantId -Path "/servicePrincipals/$($sp.id)/appRoleAssignments")
    $application = foreach ($group in ($assignments | Group-Object resourceId)) {
        $resource = Invoke-Graph -TenantId $tenantId -Path "/servicePrincipals/$($group.Name)?`$select=appId,displayName,appRoles"
        $roles = foreach ($assignment in $group.Group) { ($resource.appRoles | Where-Object id -EQ $assignment.appRoleId).value }
        $roles = @($roles | Where-Object { $_ } | Sort-Object -Unique)
        if ($roles.Count) { [ordered]@{ resourceAppId = $resource.appId; resourceName = $resource.displayName; roles = $roles } }
    }

    if ($sp.appRoleAssignmentRequired) {
        Write-Warning "'Assignment required' is ON in the reference tenant. The profile still sets it OFF so all users can sign in. Edit userAssignmentRequired if you want it ON."
    }

    [ordered]@{
        displayName            = $sp.displayName
        appId                  = $sp.appId
        delegatedPermissions   = @($delegated)
        applicationPermissions = @($application)
        userAssignmentRequired = $false
        source                 = "Reference tenant $tenantId"
        generatedUtc           = (Get-Date).ToUniversalTime().ToString('o')
    }
}

$appProfile = switch ($PSCmdlet.ParameterSetName) {
    'LoginUrl' { Get-ProfileFromLoginUrl $LoginUrl }
    'Reference' { Get-ProfileFromReferenceTenant }
    'Manual' {
        if (-not (Test-Guid $AppId)) { throw '-AppId must be a GUID.' }
        [ordered]@{
            displayName            = $DisplayName
            appId                  = $AppId
            delegatedPermissions   = @(New-GraphDelegatedEntry $GraphScope)
            applicationPermissions = @()
            userAssignmentRequired = $false
            source                 = 'Manual'
            generatedUtc           = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

if (-not $OutputPath) {
    $slug = ($appProfile.displayName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $slug = $appProfile.appId }
    $OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) "config/apps/$slug.json"
}
if (Test-Path $OutputPath) { Write-Host "Overwriting existing profile $OutputPath" -ForegroundColor Yellow }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
$json = $appProfile | ConvertTo-Json -Depth 10
$json | Set-Content -Path $OutputPath -Encoding utf8

# Round-trip through the same validation the deployment script uses.
$null = Import-TargetAppProfile -Path $OutputPath

Write-Host ''
Write-Host $json
Write-Host ''
Write-Host "Saved to $OutputPath" -ForegroundColor Green
if (@($appProfile.applicationPermissions).Count) {
    Write-Warning 'This app needs APPLICATION permissions. Run New-DeployerApp.ps1 -IncludeAppRoleAssignment, and make sure your GDAP roles include Privileged Role Administrator.'
}
Write-Host 'Next: preview the rollout on one pilot tenant:'
Write-Host '  ./scripts/Invoke-AppDeployment.ps1 -TenantId <pilot-tenant-id> -WhatIf' -ForegroundColor Cyan
