#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys one or more multi-tenant enterprise apps into your GDAP customer tenants and grants
    tenant-wide admin consent, without signing in to each tenant.

.DESCRIPTION
    You sign in once, as a partner admin, with MFA. Then, for each customer tenant, the script:
      1. Pre-consents your deployer app into the tenant through the Partner Center applicationconsents API.
      2. Exchanges your partner sign-in for a Microsoft Graph token in that tenant (GDAP roles apply).
    And for each app profile (config/apps/*.json by default):
      3. Creates the app's enterprise app (service principal) from its app ID. Nobody has to sign in
         to the app first to make it appear.
      4. Grants tenant-wide admin consent for the delegated scopes in the profile.
      5. Grants any application permissions listed in the profile.
      6. Makes sure "Assignment required" matches the profile (off by default, so every user can sign in).

    Every step checks first and only changes what is missing, so it is safe to re-run.
    Supports -WhatIf and -Confirm. Results are appended to a CSV report (one row per tenant per app)
    as soon as each tenant finishes.

.EXAMPLE
    ./Invoke-AppDeployment.ps1 -TenantId 11111111-2222-3333-4444-555555555555 -WhatIf
    Preview what would change in one pilot tenant, for every app in config/apps.

.EXAMPLE
    ./Invoke-AppDeployment.ps1 -TargetAppPath ./config/apps/contoso-portal.json -TenantId 11111111-2222-3333-4444-555555555555
    Deploy a single app to one tenant, for example a newly onboarded customer.

.EXAMPLE
    ./Invoke-AppDeployment.ps1 -ExcludeTenantId 66666666-7777-8888-9999-000000000000
    Deploy every app in config/apps to every GDAP customer except one. Asks for confirmation first.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'AllCustomers')]
param(
    # Deploy only to these customer tenant IDs (GUIDs).
    [Parameter(Mandatory, ParameterSetName = 'TenantList')]
    [string[]]$TenantId,

    # CSV with a TenantId column (and optional Name column) listing the tenants to deploy to.
    [Parameter(Mandatory, ParameterSetName = 'TenantCsv')]
    [string]$TenantCsvPath,

    # Tenant IDs to skip.
    [string[]]$ExcludeTenantId = @(),

    # App profile(s) to deploy. Defaults to every .json file in config/apps.
    [string[]]$TargetAppPath,

    [string]$DeployerConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/deployer.json'),
    [string]$ReportPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "reports/deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"),

    # The deployer app is already in every tenant; don't call the Partner Center consent API.
    [switch]$SkipDeployerConsent,

    # Remove the deployer app from each customer tenant once all apps deployed successfully there.
    [switch]$RemoveDeployerAfter,

    [switch]$UseDeviceCode,
    [string]$LoginHint,

    # Skip the bulk "are you sure?" prompt.
    [switch]$Force,

    # Also output the result objects.
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PartnerAppDeploy.psm1') -Force

$cmdlet   = $PSCmdlet
$deployer = Import-DeployerConfig -Path $DeployerConfigPath
$customerScopes = @($deployer.customerGraphScopes)

if (-not $TargetAppPath) {
    $appsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/apps'
    # Note: not `ForEach-Object FullName` - that form honours -WhatIf and would return nothing in preview mode.
    $TargetAppPath = @((Get-ChildItem -Path $appsDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name).FullName)
    if (-not $TargetAppPath) { throw "No app profiles found in $appsDir. Create one with scripts/New-TargetAppProfile.ps1 (see docs/SETUP.md, step 6)." }
}
$targets = @($TargetAppPath | ForEach-Object { Import-TargetAppProfile -Path $_ })
$duplicates = @($targets | Group-Object appId | Where-Object Count -GT 1)
if ($duplicates.Count) { throw "The same appId appears in more than one profile: $($duplicates.Name -join ', ')" }

$needsAppRoles = @($targets | Where-Object { @($_.applicationPermissions).Count })
if ($needsAppRoles.Count -and 'AppRoleAssignment.ReadWrite.All' -notin $customerScopes) {
    throw "$($needsAppRoles.displayName -join ', ') need application permissions, but the deployer app was set up without them. Run New-DeployerApp.ps1 -IncludeAppRoleAssignment first."
}

function New-ResultRow {
    param($Tenant, $Target)
    [ordered]@{
        Timestamp          = (Get-Date).ToString('s')
        TenantName         = $Tenant.Name
        TenantId           = $Tenant.TenantId
        App                = $Target.displayName
        Result             = ''
        DeployerConsent    = ''
        EnterpriseApp      = ''
        DelegatedConsent   = ''
        AppPermissions     = ''
        UserAssignment     = ''
        DeployerRemoved    = ''
        Notes              = ''
        Error              = ''
        Hint               = ''
        FallbackConsentUrl = ''
    }
}

# Steps 1-2: make sure our deployer app can act in the tenant. Never throws; the outcome is returned.
function Enable-DeployerAccess {
    param([Parameter(Mandatory)]$Tenant)

    $tid    = $Tenant.TenantId
    $label  = "$($Tenant.Name) ($tid)"
    $status = [ordered]@{ Ready = $false; DeployerConsent = ''; Result = ''; Notes = ''; Error = ''; Hint = '' }

    try {
        # 1. Bootstrap: get the deployer app consented in the customer tenant (Partner Center).
        $consentJustGranted = $false
        if ($tid -eq $partnerTenantId) {
            $status.DeployerConsent = 'NotNeeded'
        } elseif ($SkipDeployerConsent) {
            $status.DeployerConsent = 'Skipped'
        } elseif ($cmdlet.ShouldProcess($label, 'Pre-consent deployer app via Partner Center')) {
            $status.DeployerConsent = Grant-DeployerConsent -CustomerTenantId $tid -GraphScopes $customerScopes
            $consentJustGranted = $status.DeployerConsent -eq 'Granted'
        } else {
            $status.DeployerConsent = 'WhatIf'
        }

        # 2. Exchange the partner sign-in for a Graph token in this tenant.
        try {
            $access = Wait-DeployerTenantAccess -TenantId $tid -RequiredScopes $customerScopes -Attempts ($consentJustGranted ? 9 : 1)
        } catch {
            if ($status.DeployerConsent -ne 'WhatIf') { throw }
            $status.Result = 'WhatIf'
            $status.Notes = 'Deployer app is not in this tenant yet, so nothing further can be previewed.'
            return $status
        }
        # Getting a token proves the deployer is already consented here.
        if ($status.DeployerConsent -eq 'WhatIf') { $status.DeployerConsent = 'AlreadyPresent' }

        if ($access.MissingScopes.Count) {
            $missingText = $access.MissingScopes -join ', '
            if ($status.DeployerConsent -in 'NotNeeded', 'Skipped') {
                throw "The deployer app's consent in this tenant lacks: $missingText. Re-run New-DeployerApp.ps1 / drop -SkipDeployerConsent."
            }
            if (-not $cmdlet.ShouldProcess($label, "Re-consent deployer app (missing $missingText)")) {
                $status.Result = $WhatIfPreference ? 'WhatIf' : 'Skipped'
                $status.Notes = "Deployer consent would be refreshed (missing $missingText)."
                return $status
            }
            $null = Remove-DeployerConsent -CustomerTenantId $tid
            $null = Grant-DeployerConsent -CustomerTenantId $tid -GraphScopes $customerScopes
            $status.DeployerConsent = 'Refreshed'
            $access = Wait-DeployerTenantAccess -TenantId $tid -RequiredScopes $customerScopes -Attempts 9
            if ($access.MissingScopes.Count) { throw "The deployer app still lacks: $($access.MissingScopes -join ', ')" }
        }
        $status.Ready = $true
    } catch {
        $status.Result = 'Failed'
        $status.Error = $_.Exception.Message
        $status.Hint = Get-FailureHint $_.Exception.Message
    }
    $status
}

# Steps 3-6 for one app in one tenant. Returns the result row.
function Install-TargetApp {
    param([Parameter(Mandatory)]$Tenant, [Parameter(Mandatory)]$Target, [string]$DeployerConsent)

    $tid   = $Tenant.TenantId
    $label = "$($Tenant.Name) ($tid)"
    $row   = New-ResultRow $Tenant $Target
    $row.DeployerConsent = $DeployerConsent
    $changed = $false   # something was actually modified
    $pending = $false   # something would change, but -WhatIf / -Confirm said no
    $spIsNew = $false

    try {
        # 3. The enterprise app itself: a service principal for the vendor's multi-tenant app.
        #    Entra's Enterprise applications list (default filter) only shows service principals tagged
        #    WindowsAzureActiveDirectoryIntegratedApp. Consent through the UI sets it; a bare Graph create does not.
        $listedTag = 'WindowsAzureActiveDirectoryIntegratedApp'
        $sp = Get-ServicePrincipalByAppId -TenantId $tid -AppId $Target.appId
        if ($sp) {
            $row.EnterpriseApp = 'Exists'
            if ($listedTag -notin @($sp.tags)) {
                if ($cmdlet.ShouldProcess($label, "Show '$($Target.displayName)' in the Enterprise applications list")) {
                    # PATCH replaces the whole tags collection, so keep the existing tags.
                    $tags = @(@($sp.tags) + $listedTag | Where-Object { $_ })
                    $null = Invoke-Graph -TenantId $tid -Method PATCH -Path "/servicePrincipals/$($sp.id)" -Body @{ tags = $tags }
                    $row.EnterpriseApp = 'Exists (now listed)'
                    $changed = $true
                } else {
                    $row.EnterpriseApp = 'Exists (WouldList)'
                    $pending = $true
                }
            }
        } elseif ($cmdlet.ShouldProcess($label, "Create enterprise app '$($Target.displayName)'")) {
            $sp = Invoke-Graph -TenantId $tid -Method POST -Path '/servicePrincipals' -Body @{ appId = $Target.appId; tags = @($listedTag) }
            $row.EnterpriseApp = 'Created'
            $changed = $true
            $spIsNew = $true
        } else {
            $row.EnterpriseApp = 'WouldCreate'
            $pending = $true
        }
        if ($sp -and $sp.accountEnabled -eq $false) {
            $row.Notes = "'Enabled for users to sign-in' is OFF for this app in this tenant. Left as-is."
        }

        # 4. Tenant-wide admin consent for delegated scopes (what "Accept on behalf of your organization" does).
        $grantResults = foreach ($perm in $Target.delegatedPermissions) {
            $resource = Get-ServicePrincipalByAppId -TenantId $tid -AppId $perm.resourceAppId -Select 'id,appId,displayName'
            if (-not $resource) { throw "API '$($perm.resourceName)' ($($perm.resourceAppId)) has no service principal in this tenant." }
            $wanted = @($perm.scopes)
            $existing = $null
            if ($sp) {
                $existing = Get-GraphCollection -TenantId $tid -Path "/oauth2PermissionGrants?`$filter=clientId eq '$($sp.id)'" |
                    Where-Object { $_.consentType -eq 'AllPrincipals' -and $_.resourceId -eq $resource.id } |
                    Select-Object -First 1
            }

            if (-not $existing) {
                if ($sp -and $cmdlet.ShouldProcess($label, "Grant admin consent for '$($Target.displayName)' on $($resource.displayName): $($wanted -join ' ')")) {
                    # A brand-new service principal can take a few seconds to be usable as a grant client.
                    $null = Invoke-WithRetry -Activity 'Create permission grant' -Attempts ($spIsNew ? 6 : 1) -ScriptBlock {
                        Invoke-Graph -TenantId $tid -Method POST -Path '/oauth2PermissionGrants' -Body @{
                            clientId    = $sp.id
                            consentType = 'AllPrincipals'
                            resourceId  = $resource.id
                            scope       = ($wanted -join ' ')
                        }
                    }
                    $changed = $true
                    "$($resource.displayName): Granted"
                } else {
                    $pending = $true
                    "$($resource.displayName): WouldGrant"
                }
                continue
            }

            $current = @($existing.scope -split ' ' | Where-Object { $_ })
            $missing = @($wanted | Where-Object { $_ -notin $current })
            if ($missing.Count -eq 0) {
                "$($resource.displayName): OK"
            } elseif ($cmdlet.ShouldProcess($label, "Add consented scopes for '$($Target.displayName)' on $($resource.displayName): $($missing -join ' ')")) {
                $null = Invoke-Graph -TenantId $tid -Method PATCH -Path "/oauth2PermissionGrants/$($existing.id)" -Body @{ scope = (($current + $missing) -join ' ') }
                $changed = $true
                "$($resource.displayName): Updated (+$($missing -join ' '))"
            } else {
                $pending = $true
                "$($resource.displayName): WouldAdd $($missing -join ' ')"
            }
        }
        $row.DelegatedConsent = $grantResults ? ($grantResults -join '; ') : 'None requested'

        # 5. Application permissions (app roles). Only if the profile lists any.
        $roleResults = foreach ($perm in $Target.applicationPermissions) {
            $resource = Get-ServicePrincipalByAppId -TenantId $tid -AppId $perm.resourceAppId -Select 'id,appId,displayName,appRoles'
            if (-not $resource) { throw "API '$($perm.resourceName)' ($($perm.resourceAppId)) has no service principal in this tenant." }
            $assigned = $sp ? @(Get-GraphCollection -TenantId $tid -Path "/servicePrincipals/$($sp.id)/appRoleAssignments") : @()
            foreach ($roleName in @($perm.roles)) {
                $role = $resource.appRoles | Where-Object { $_.value -eq $roleName -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
                if (-not $role) { throw "Application permission '$roleName' does not exist on $($resource.displayName)." }
                if ($assigned | Where-Object { $_.resourceId -eq $resource.id -and $_.appRoleId -eq $role.id }) {
                    "${roleName}: OK"
                } elseif ($sp -and $cmdlet.ShouldProcess($label, "Grant application permission to '$($Target.displayName)': $($resource.displayName) / $roleName")) {
                    $null = Invoke-Graph -TenantId $tid -Method POST -Path "/servicePrincipals/$($sp.id)/appRoleAssignments" -Body @{
                        principalId = $sp.id
                        resourceId  = $resource.id
                        appRoleId   = $role.id
                    }
                    $changed = $true
                    "${roleName}: Granted"
                } else {
                    $pending = $true
                    "${roleName}: WouldGrant"
                }
            }
        }
        $row.AppPermissions = $roleResults ? ($roleResults -join '; ') : 'None requested'

        # 6. "Assignment required?" - off means every user in the tenant can sign in.
        if ($null -eq $Target.userAssignmentRequired) {
            $row.UserAssignment = 'NotManaged'
        } else {
            $desired = [bool]$Target.userAssignmentRequired
            $desiredText = $desired ? 'Required' : 'NotRequired'
            if (-not $sp) {
                # New service principals default to NotRequired.
                if ($desired) { $row.UserAssignment = "WouldSet $desiredText"; $pending = $true } else { $row.UserAssignment = 'NotRequired' }
            } elseif ([bool]$sp.appRoleAssignmentRequired -eq $desired) {
                $row.UserAssignment = $desiredText
            } elseif ($cmdlet.ShouldProcess($label, "Set 'Assignment required' to $desired for '$($Target.displayName)'")) {
                $null = Invoke-Graph -TenantId $tid -Method PATCH -Path "/servicePrincipals/$($sp.id)" -Body @{ appRoleAssignmentRequired = $desired }
                $row.UserAssignment = "Changed to $desiredText"
                $changed = $true
            } else {
                $row.UserAssignment = "WouldSet $desiredText"
                $pending = $true
            }
        }

        $row.Result = if ($pending) { $WhatIfPreference ? 'WhatIf' : 'Skipped' } elseif ($changed) { 'Deployed' } else { 'AlreadyDone' }
    } catch {
        $row.Result = 'Failed'
        $row.Error = $_.Exception.Message
        $row.Hint = Get-FailureHint $_.Exception.Message
    }
    if ($row.Result -eq 'Failed') {
        # Manual fallback: a Global Admin of this tenant (or you, with enough GDAP rights) can open this once.
        $row.FallbackConsentUrl = "https://login.microsoftonline.com/$tid/adminconsent?client_id=$($Target.appId)"
    }
    $row
}

function Invoke-TenantDeployment {
    param([Parameter(Mandatory)]$Tenant)

    $access = Enable-DeployerAccess -Tenant $Tenant
    $rows = foreach ($target in $targets) {
        if ($access.Ready) {
            Install-TargetApp -Tenant $Tenant -Target $target -DeployerConsent $access.DeployerConsent
        } else {
            # Couldn't get into the tenant: one row per app carrying the reason.
            $row = New-ResultRow $Tenant $target
            foreach ($field in 'Result', 'DeployerConsent', 'Notes', 'Error', 'Hint') { $row[$field] = $access[$field] }
            if ($row.Result -eq 'Failed') { $row.FallbackConsentUrl = "https://login.microsoftonline.com/$($Tenant.TenantId)/adminconsent?client_id=$($target.appId)" }
            $row
        }
    }

    # 7. Optional clean-up of the deployer app, only once every app succeeded in this tenant.
    if ($RemoveDeployerAfter -and $access.Ready -and $Tenant.TenantId -ne $partnerTenantId -and -not ($rows | Where-Object { $_.Result -eq 'Failed' })) {
        $removed = 'WhatIf'
        if ($cmdlet.ShouldProcess("$($Tenant.Name) ($($Tenant.TenantId))", 'Remove deployer app consent')) {
            try { $removed = Remove-DeployerConsent -CustomerTenantId $Tenant.TenantId }
            catch { $removed = "Failed: $($_.Exception.Message)" }
        }
        foreach ($row in $rows) { $row.DeployerRemoved = $removed }
    }
    foreach ($row in $rows) { [pscustomobject]$row }
}

# --- Sign in once -------------------------------------------------------------------------------

$null = Connect-Deployer -PartnerTenantId $deployer.partnerTenantId -ClientId $deployer.clientId -UseDeviceCode:$UseDeviceCode -LoginHint $LoginHint
$partnerTenantId = (Get-DeployerSession).PartnerTenantId

# --- Work out which tenants to process ----------------------------------------------------------

Write-Host 'Loading GDAP customers...' -ForegroundColor Cyan
$gdapCustomers = @()
try {
    $gdapCustomers = @(Get-GdapCustomer)
} catch {
    if ($PSCmdlet.ParameterSetName -eq 'AllCustomers') { throw }
    Write-Warning "Couldn't load the GDAP customer list, so tenant names won't be shown: $($_.Exception.Message)"
}

$tenants = switch ($PSCmdlet.ParameterSetName) {
    'TenantList' {
        foreach ($id in $TenantId) {
            $match = $gdapCustomers | Where-Object TenantId -EQ $id.Trim() | Select-Object -First 1
            [pscustomobject]@{ TenantId = $id.Trim(); Name = $match ? $match.Name : $id.Trim() }
        }
    }
    'TenantCsv' {
        foreach ($line in (Import-Csv -Path $TenantCsvPath)) {
            $id = "$($line.TenantId)".Trim()
            [pscustomobject]@{ TenantId = $id; Name = $line.Name ? $line.Name : $id }
        }
    }
    default { $gdapCustomers }
}
$tenants = @($tenants | Where-Object { $_.TenantId -notin $ExcludeTenantId } | Sort-Object TenantId -Unique | Sort-Object Name)

$invalid = @($tenants | Where-Object { -not (Test-Guid $_.TenantId) })
if ($invalid.Count) { throw "These tenant IDs are not GUIDs: $($invalid.TenantId -join ', ')" }
if ($tenants.Count -eq 0) { Write-Warning 'No tenants to process.'; return }

Write-Host ''
foreach ($target in $targets) {
    Write-Host "App      : $($target.displayName) ($($target.appId))"
    Write-Host "  Consent: $(($target.delegatedPermissions | ForEach-Object { "$($_.resourceName): $($_.scopes -join ' ')" }) -join ' | ')"
}
Write-Host "Tenants  : $($tenants.Count)"
Write-Host "Report   : $ReportPath"
Write-Host ''

$appText = $targets.Count -eq 1 ? "'$($targets[0].displayName)'" : "$($targets.Count) apps"
if (-not $WhatIfPreference -and -not $Force -and $tenants.Count -gt 1 -and
    -not $PSCmdlet.ShouldContinue("Deploy $appText and grant admin consent in $($tenants.Count) customer tenants?", 'Confirm bulk deployment')) {
    Write-Host 'Cancelled.'
    return
}

# --- Deploy -------------------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) -WhatIf:$false | Out-Null
$results = [Collections.Generic.List[object]]::new()
$colors = @{ Deployed = 'Green'; AlreadyDone = 'DarkGreen'; Failed = 'Red' }
$index = 0
foreach ($tenant in $tenants) {
    $index++
    Write-Progress -Activity 'Deploying enterprise apps' -Status "$index/$($tenants.Count): $($tenant.Name)" -PercentComplete (100 * ($index - 1) / $tenants.Count)

    $rows = @(Invoke-TenantDeployment -Tenant $tenant)
    $rows | Export-Csv -Path $ReportPath -Append -NoTypeInformation -WhatIf:$false
    Write-Host ('[{0}/{1}] {2}' -f $index, $tenants.Count, $tenant.Name)
    foreach ($row in $rows) {
        $results.Add($row)
        Write-Host ('    {0} - {1}' -f $row.App, $row.Result) -ForegroundColor ($colors[$row.Result] ?? 'Yellow')
        if ($row.Error) { Write-Host "        $($row.Error)" -ForegroundColor DarkRed }
        if ($row.Hint) { Write-Host "        Hint: $($row.Hint)" -ForegroundColor DarkYellow }
        if ($row.Notes) { Write-Host "        Note: $($row.Notes)" -ForegroundColor DarkGray }
    }
}
Write-Progress -Activity 'Deploying enterprise apps' -Completed

Write-Host ''
Write-Host 'Summary (tenant x app)' -ForegroundColor Cyan
$results | Group-Object Result | Sort-Object Name | ForEach-Object { Write-Host ('  {0,-12} {1}' -f $_.Name, $_.Count) }
Write-Host "Report: $ReportPath"

if ($PassThru) { $results }
