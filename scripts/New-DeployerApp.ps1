#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    One-time setup: registers the multi-tenant "deployer" app in your partner tenant.

.DESCRIPTION
    Creates (or updates) an app registration that:
      * is multi-tenant, so Partner Center can pre-consent it into customer tenants;
      * is a public client (no secret to store or rotate) with an http://localhost redirect URI;
      * has DELEGATED permissions only. It can do nothing unless a partner admin signs in with MFA,
        and even then only what that admin's GDAP roles allow in each customer tenant.

    It then grants admin consent for the app in the partner tenant and writes config/deployer.json,
    which the other scripts read.

    Run this as a Global Administrator (or Privileged Role Administrator) of the PARTNER tenant.
    Re-running it is safe: it updates the existing app instead of creating a second one.

.PARAMETER PartnerTenantId
    Your partner tenant ID (GUID) or primary domain, e.g. contoso.onmicrosoft.com.

.PARAMETER IncludeAppRoleAssignment
    Also let the deployer grant APPLICATION permissions (app roles) to target apps.
    Not needed for typical "Sign in with Microsoft" apps, which only use delegated sign-in scopes.

.EXAMPLE
    ./New-DeployerApp.ps1 -PartnerTenantId contoso.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PartnerTenantId,
    [string]$DisplayName = 'MSP Enterprise App Deployer',
    [switch]$IncludeAppRoleAssignment,
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/deployer.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PartnerAppDeploy.psm1') -Force

$GraphAppId         = '00000003-0000-0000-c000-000000000000'
$PartnerCenterAppId = 'fa3d9a0c-3fb0-42cc-9193-47c7ecd2edbd'   # Microsoft Partner Center API

# Scopes the deployer needs inside each customer tenant. Partner Center pushes exactly these.
$customerGraphScopes = @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All')
if ($IncludeAppRoleAssignment) { $customerGraphScopes += 'AppRoleAssignment.ReadWrite.All' }
# Scopes only used in the partner tenant: list GDAP customers, plus basic sign-in.
$partnerOnlyGraphScopes = @('DelegatedAdminRelationship.Read.All', 'offline_access', 'openid', 'profile')
$graphScopes         = $customerGraphScopes + $partnerOnlyGraphScopes
$partnerCenterScopes = @('user_impersonation')

function Invoke-MgRest([string]$Method, [string]$Path, $Body) {
    $request = @{ Method = $Method; Uri = "https://graph.microsoft.com/v1.0$Path"; OutputType = 'PSObject' }
    if ($null -ne $Body) {
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 10
        $request.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @request
}

function Get-ServicePrincipal([string]$AppId) {
    @((Invoke-MgRest GET "/servicePrincipals?`$filter=appId eq '$AppId'").value) | Select-Object -First 1
}

function Get-ScopeAccess($ServicePrincipal, [string[]]$Names) {
    foreach ($name in $Names) {
        $scope = $ServicePrincipal.oauth2PermissionScopes | Where-Object value -EQ $name
        if (-not $scope) { throw "Permission '$name' was not found on $($ServicePrincipal.displayName)." }
        @{ id = $scope.id; type = 'Scope' }
    }
}

# Tenant-wide (AllPrincipals) delegated consent, merged with anything already granted.
function Set-AdminConsent($ClientSp, $ResourceSp, [string[]]$Scopes) {
    $existing = @((Invoke-MgRest GET "/oauth2PermissionGrants?`$filter=clientId eq '$($ClientSp.id)'").value) |
        Where-Object { $_.consentType -eq 'AllPrincipals' -and $_.resourceId -eq $ResourceSp.id } |
        Select-Object -First 1
    if ($existing) {
        $merged = @(@($existing.scope -split ' ' | Where-Object { $_ }) + $Scopes | Sort-Object -Unique)
        $null = Invoke-MgRest PATCH "/oauth2PermissionGrants/$($existing.id)" @{ scope = $merged -join ' ' }
    } else {
        $null = Invoke-MgRest POST '/oauth2PermissionGrants' @{
            clientId    = $ClientSp.id
            consentType = 'AllPrincipals'
            resourceId  = $ResourceSp.id
            scope       = $Scopes -join ' '
        }
    }
}

Write-Host "Connecting to partner tenant $PartnerTenantId (sign in as a partner Global Administrator)..." -ForegroundColor Cyan
Connect-MgGraph -TenantId $PartnerTenantId -Scopes 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All' -NoWelcome
$tenantGuid = (Get-MgContext).TenantId

try {
    $graphSp = Get-ServicePrincipal $GraphAppId
    $partnerCenterSp = Get-ServicePrincipal $PartnerCenterAppId
    if (-not $partnerCenterSp) {
        Write-Host 'Adding the Microsoft Partner Center API to the partner tenant...'
        $null = Invoke-MgRest POST '/servicePrincipals' @{ appId = $PartnerCenterAppId }
        $partnerCenterSp = Invoke-WithRetry -Activity 'Read Partner Center service principal' -ScriptBlock {
            $sp = Get-ServicePrincipal $PartnerCenterAppId
            if (-not $sp) { throw 'Not replicated yet.' }
            $sp
        }
    }

    $appBody = @{
        displayName            = $DisplayName
        signInAudience         = 'AzureADMultipleOrgs'
        isFallbackPublicClient = $true
        publicClient           = @{ redirectUris = @('http://localhost') }
        requiredResourceAccess = @(
            @{ resourceAppId = $GraphAppId; resourceAccess = @(Get-ScopeAccess $graphSp $graphScopes) }
            @{ resourceAppId = $PartnerCenterAppId; resourceAccess = @(Get-ScopeAccess $partnerCenterSp $partnerCenterScopes) }
        )
    }

    $safeName = $DisplayName.Replace("'", "''")
    $existingApps = @((Invoke-MgRest GET "/applications?`$filter=displayName eq '$safeName'&`$select=id,appId,displayName").value)
    if ($existingApps.Count -gt 1) {
        throw "More than one app registration is named '$DisplayName'. Delete the extras, or pass a different -DisplayName."
    }
    if ($existingApps.Count -eq 1) {
        $app = $existingApps[0]
        Write-Host "Updating existing app registration '$DisplayName' ($($app.appId))..."
        $null = Invoke-MgRest PATCH "/applications/$($app.id)" $appBody
    } else {
        Write-Host "Creating app registration '$DisplayName'..."
        $app = Invoke-MgRest POST '/applications' $appBody
    }

    $deployerSp = Get-ServicePrincipal $app.appId
    if (-not $deployerSp) {
        $deployerSp = Invoke-WithRetry -Activity 'Create deployer service principal' -Attempts 8 -ScriptBlock {
            Invoke-MgRest POST '/servicePrincipals' @{ appId = $app.appId }
        }
    }

    Write-Host 'Granting admin consent in the partner tenant...'
    Invoke-WithRetry -Activity 'Grant admin consent' -Attempts 6 -ScriptBlock {
        Set-AdminConsent $deployerSp $graphSp $graphScopes
        Set-AdminConsent $deployerSp $partnerCenterSp $partnerCenterScopes
    }

    $config = [ordered]@{
        partnerTenantId     = $tenantGuid
        clientId            = $app.appId
        displayName         = $DisplayName
        customerGraphScopes = $customerGraphScopes
        updatedUtc          = (Get-Date).ToUniversalTime().ToString('o')
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    $config | ConvertTo-Json | Set-Content -Path $OutputPath -Encoding utf8

    Write-Host ''
    Write-Host 'Deployer app is ready.' -ForegroundColor Green
    Write-Host "  App (client) ID : $($app.appId)"
    Write-Host "  Partner tenant  : $tenantGuid"
    Write-Host "  Config written  : $OutputPath"
    Write-Host ''
    Write-Host 'Next: check GDAP readiness, then build a profile for each app (docs/SETUP.md, steps 5-6):'
    Write-Host '  ./scripts/Test-GdapReadiness.ps1' -ForegroundColor Cyan
    Write-Host "  ./scripts/New-TargetAppProfile.ps1 -DisplayName '<App name>' -LoginUrl '<Microsoft sign-in URL from the app>'" -ForegroundColor Cyan
} finally {
    Disconnect-MgGraph | Out-Null
}
