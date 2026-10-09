# Runbook

Assumes [SETUP.md](SETUP.md) is complete: `config/deployer.json` exists, and `config/apps/` has at least one app profile.

Run everything from the repo root in **PowerShell 7** (`pwsh`). Each run opens a browser once for you to sign in to the **partner** tenant with MFA. Nothing is stored between runs.

By default every run deploys **every profile in `config/apps/`**. Use `-TargetAppPath` to pick specific profiles.

---

## 1. Pilot on one tenant

Pick a friendly customer, or a test tenant you manage through GDAP.

```powershell
# Preview only - prints "What if:" lines and changes nothing
./scripts/Invoke-AppDeployment.ps1 -TenantId <pilot-tenant-id> -WhatIf

# Do it
./scripts/Invoke-AppDeployment.ps1 -TenantId <pilot-tenant-id>

# Just one app
./scripts/Invoke-AppDeployment.ps1 -TenantId <pilot-tenant-id> -TargetAppPath ./config/apps/contoso-portal.json
```

> In `-WhatIf` mode the deployer app isn't pushed, so for a tenant that has never had it, the preview stops at *"Deployer app is not in this tenant yet"*. That's expected. The real run handles it.

### Verify in the customer's tenant

Open the Entra admin center for that customer. In Partner Center: *Customers → (customer) → Service management → Microsoft Entra ID*.

1. **Enterprise applications** → set the *Application type* filter to **All applications** → search for the app by its **Application ID** (the `appId` in your profile). Search by ID because the name shown comes from the vendor's registration, not your profile's `displayName`.
2. Open it → **Permissions → Admin consent**. The scopes from your profile should be listed as granted by an admin.
3. **Properties**: *Enabled for users to sign-in?* **Yes**, and *Assignment required?* **No** (unless your profile says otherwise).

### Verify as a user

In a private browser window, sign in to the vendor's app as **a normal user** from that customer, using its *Sign in with Microsoft* button. They should go straight in, with no consent screen and no *Need admin approval*.

If they still see a consent screen, the app asked for a scope that isn't in your profile. Rebuild the profile (SETUP step 6, option A) and re-run. Only the missing scope gets added.

## 2. Roll out to everyone

```powershell
# Preview every GDAP customer
./scripts/Invoke-AppDeployment.ps1 -WhatIf

# Do it (asks "are you sure?" once; add -Force to skip the prompt)
./scripts/Invoke-AppDeployment.ps1

# Skip specific tenants
./scripts/Invoke-AppDeployment.ps1 -ExcludeTenantId <id1>, <id2>

# Only the tenants in a CSV (needs a TenantId column; Name is optional)
./scripts/Invoke-AppDeployment.ps1 -TenantCsvPath ./my-tenants.csv
```

"Every customer" means every customer returned by Microsoft Graph `tenantRelationships/delegatedAdminCustomers`, i.e. customers with a GDAP relationship.

### Retry only the failures

Fix the cause using the `Hint` column, then:

```powershell
Import-Csv ./reports/deploy-<timestamp>.csv | Where-Object Result -eq 'Failed' |
    Select-Object TenantId, TenantName -Unique | Export-Csv ./reports/retry.csv -NoTypeInformation
./scripts/Invoke-AppDeployment.ps1 -TenantCsvPath ./reports/retry.csv
```

## 3. Adding another app later

1. Build its profile (SETUP step 6). It lands in `config/apps/`.
2. Pilot it on one tenant with `-TargetAppPath ./config/apps/<new-app>.json`.
3. Run the full rollout. Apps that are already deployed report `AlreadyDone` and aren't touched.

## 4. Onboarding a new customer

Once the new customer's GDAP relationship (including *Cloud Application Administrator*) is active and assigned:

```powershell
./scripts/Invoke-AppDeployment.ps1 -TenantId <new-tenant-id>
```

That deploys every app in `config/apps/` to the new customer. Or just re-run the full rollout: tenants that are already done aren't touched.

## 5. Reading the report

Every run writes `reports/deploy-<timestamp>.csv` with **one row per tenant per app**. Rows are appended as each tenant finishes, so a cancelled run still leaves a partial report.

| Column | Values |
|---|---|
| `App` | The profile's `displayName` |
| `Result` | `Deployed` (something changed) · `AlreadyDone` (nothing needed) · `WhatIf` (preview) · `Skipped` (you said no at a `-Confirm` prompt) · `Failed` |
| `DeployerConsent` | `Granted` · `AlreadyPresent` · `Refreshed` (the deployer's scopes were updated) · `NotNeeded` (partner tenant) · `Skipped` |
| `EnterpriseApp` | `Created` · `Exists` · `Exists (now listed)` (tag added so it shows in the Enterprise applications list) · `WouldCreate` |
| `DelegatedConsent` | Per API: `Granted` · `OK` · `Updated (+scopes)` · `WouldGrant` |
| `AppPermissions` | Per role: `Granted` · `OK` · `WouldGrant`, or `None requested` |
| `UserAssignment` | `NotRequired` · `Required` · `Changed to …` · `NotManaged` |
| `DeployerRemoved` | Only with `-RemoveDeployerAfter`: `Removed` · `NotPresent` |
| `Notes` | Things worth knowing that aren't errors, e.g. the app is disabled for sign-in in that tenant |
| `Error`, `Hint` | What went wrong and what to do (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)) |
| `FallbackConsentUrl` | Failed rows only: an admin-consent link for that app in that tenant, for the rare customer you have to do by hand |

## 6. Useful switches

| Switch | Use |
|---|---|
| `-WhatIf` | Preview. Changes nothing (not even the deployer app). |
| `-Confirm` | Ask before every individual change. |
| `-TargetAppPath <file(s)>` | Deploy only these profiles instead of everything in `config/apps/`. |
| `-RemoveDeployerAfter` | Once every app succeeded in a tenant, remove the deployer app from it. Leaves the least footprint. The next run re-adds it automatically. |
| `-SkipDeployerConsent` | Don't call Partner Center. Use this if the deployer is already in every tenant, e.g. when Partner Center is having an outage. |
| `-UseDeviceCode` | Sign in with a device code instead of a browser redirect. Often blocked by Conditional Access. |
| `-LoginHint you@yourmsp.com` | Pre-fill the sign-in account. |
| `-PassThru` | Also output the result objects, for further scripting. |

## 7. Rolling back

**One app in one tenant, by hand:** in that tenant's Entra admin center, go to *Enterprise applications* → the app → *Properties* → **Delete**. Deleting the enterprise app also removes its consent grants. Users will get the consent prompt again on their next sign-in.

**Scripted** (requires the deployer to still be in that tenant):

```powershell
Import-Module ./src/PartnerAppDeploy.psm1
$cfg    = Import-DeployerConfig ./config/deployer.json
$target = Import-TargetAppProfile ./config/apps/contoso-portal.json
Connect-Deployer -PartnerTenantId $cfg.partnerTenantId -ClientId $cfg.clientId

$tenant = '<tenant-id>'
$sp = Get-ServicePrincipalByAppId -TenantId $tenant -AppId $target.appId
Invoke-Graph -TenantId $tenant -Method DELETE -Path "/servicePrincipals/$($sp.id)"

# And remove the deployer app itself from that tenant:
Remove-DeployerConsent -CustomerTenantId $tenant
```

**Remove the deployer from every customer** without touching the deployed apps:

```powershell
Get-GdapCustomer | ForEach-Object { '{0}: {1}' -f $_.Name, (Remove-DeployerConsent -CustomerTenantId $_.TenantId) }
```

## 8. Audit trail and housekeeping

- Each customer tenant's **Entra audit log** records *Add service principal* and *Add delegated permission grant* events, performed by your partner user. They're traceable, like any other GDAP action.
- The deployer app has **no secret that expires**. Nothing needs rotating.
- If a vendor changes the scopes their app requests, rebuild that profile and re-run. Existing grants are extended, never reduced.
- To change what the deployer itself can do (e.g. add `-IncludeAppRoleAssignment`), re-run `New-DeployerApp.ps1`. The next rollout spots that customer tenants are missing a scope and refreshes the deployer's consent there (`DeployerConsent = Refreshed`).
