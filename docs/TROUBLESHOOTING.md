# Troubleshooting

Each failed tenant in the report has `Error` and `Hint` columns. Look up the error code or message below.

## Signing in (partner tenant)

| Error | Cause | Fix |
|---|---|---|
| `AADSTS50011` redirect URI mismatch | `http://localhost` isn't registered as a **Public client / native** redirect URI | Re-run `New-DeployerApp.ps1`, or add it under *Authentication → Mobile and desktop applications* |
| `AADSTS7000218` request must contain `client_secret` | *Allow public client flows* is off | Re-run `New-DeployerApp.ps1`, or set *Authentication → Allow public client flows* to **Yes** |
| `AADSTS65001` / consent prompt at sign-in | The deployer isn't admin-consented in your partner tenant | Re-run `New-DeployerApp.ps1` as a partner Global Admin, or click *Grant admin consent* on the app |
| `AADSTS53003` with `-UseDeviceCode` | Conditional Access blocks device code flow (common, and a good policy) | Drop `-UseDeviceCode` and use the browser sign-in |
| "You signed in to tenant X, but the deployer lives in partner tenant Y" | You picked a customer or guest account in the browser | Sign in with your partner account. Use `-LoginHint you@yourmsp.com` to pre-select it |
| "This sign-in has no MFA claim" warning | Your sign-in didn't perform MFA | Make sure a Conditional Access policy requires MFA for partner admins. Partner Center calls will fail without it |
| Browser didn't open / timed out | Locked-down workstation, or the browser opened on another desktop | Copy the URL printed in the console into a browser on the same machine, or use `-UseDeviceCode` |

## Partner Center consent (hop 1)

| Error | Cause | Fix |
|---|---|---|
| `Partner Center consent failed (HTTP 401)` | The token lacks MFA, or the deployer isn't consented for Partner Center `user_impersonation` in your partner tenant | Sign in again with MFA. Re-run `New-DeployerApp.ps1` |
| `Partner Center consent failed (HTTP 403)` | You're not in **AdminAgents**, or you don't hold Cloud Application Administrator / Application Administrator through GDAP for that customer | Run `Test-GdapReadiness.ps1`. See [SETUP.md step 1](SETUP.md#1-check-gdap-roles) |
| `Partner Center consent failed (HTTP 404)` | Partner Center doesn't recognise the customer ID. This can happen for customers you manage through GDAP without a CSP/reseller relationship | Confirm the tenant ID. If the customer isn't addressable through Partner Center, use the `FallbackConsentUrl` from the report once (see below) |
| `... lacks a service principal for ...` (HTTP 400) | An API the deployer needs isn't provisioned in the customer tenant | Unusual for Microsoft Graph. Open a ticket with Microsoft if it happens |

## Getting into the customer tenant

| Error | Cause | Fix |
|---|---|---|
| `AADSTS90099` application not authorized in the tenant | The deployer app isn't consented there yet. This is the original block | Don't use `-SkipDeployerConsent`. Check whether that tenant's Partner Center step failed |
| `AADSTS50020` / `AADSTS90072` / `AADSTS50034` user not in tenant | No working GDAP access: the relationship expired, or your user isn't in a group assigned to it | Renew the GDAP relationship, or add yourself to the right security group |
| `AADSTS50076` / `AADSTS50079` / `AADSTS53003` / `AADSTS50158` | The **customer's** Conditional Access applies to service-provider users and blocks you (MFA method, device compliance, location) | Adjust the customer's CA policy exclusions for service provider users. Microsoft recommends trusting the partner tenant's MFA through cross-tenant access settings |
| "The deployer app's consent in this tenant lacks: …" | The deployer was consented earlier with fewer scopes | Run again without `-SkipDeployerConsent`. The script removes and re-adds the deployer's consent automatically (`DeployerConsent = Refreshed`) |

## Creating the app and granting consent (hop 2)

| Error | Cause | Fix |
|---|---|---|
| `Authorization_RequestDenied` / `Insufficient privileges` (HTTP 403) | Your GDAP roles in that tenant can't create service principals or grant consent | You need Cloud Application Administrator or Application Administrator. You also need Privileged Role Administrator if the profile has Graph *application* permissions |
| `does not reference a valid application object` / `NoBackingApplicationObject` | The `appId` in that app's profile is wrong, or the vendor app isn't multi-tenant | Rebuild the profile (SETUP step 6) and double-check the ID |
| `API '…' has no service principal in this tenant` | The profile includes a non-Graph API that doesn't exist in that tenant | Usually means the profile came from a tenant with extra services. Remove that entry if the app doesn't need it |
| `Application permission '…' does not exist` | Typo or renamed role in `applicationPermissions` | Rebuild the profile with `-ReferenceTenantId` |

## After deployment: users still see a prompt

| Symptom | Cause | Fix |
|---|---|---|
| Users see a consent screen listing permissions | The app requests a scope that isn't in your profile, e.g. `offline_access` | Rebuild the profile from the login URL (SETUP step 6, option A) and re-run. Only the missing scope is added |
| Users see *Need admin approval* | Same as above, in a tenant where user consent is disabled | Same fix |
| *AADSTS50105: … not assigned to a role for the application* | *Assignment required* is **Yes** in that tenant | Keep `userAssignmentRequired: false` in the profile and re-run, or assign users or groups to the app |
| *AADSTS7000112: application is disabled* | Someone set *Enabled for users to sign-in* to **No** in that tenant (reported in `Notes`) | The script deliberately leaves this alone. Turn it back on in that tenant if it should be enabled |

## The manual fallback for a single stubborn tenant

Failed rows include `FallbackConsentUrl`:

```
https://login.microsoftonline.com/<tenant-id>/adminconsent?client_id=<vendor-app-id>
```

Open it while signed in as **a Global Administrator of that tenant**. You can send it to the client's admin, or use it yourself if your GDAP access allows. One click creates the enterprise app and grants the app's registered permissions, with no user sign-in attempt needed first. Then re-run the script for that tenant to set *Assignment required* and confirm the scopes.

## Still stuck?

- Run with `-Verbose` to see each retry and Graph call that failed.
- Decode the token to see which scopes and roles you actually hold in a tenant:

```powershell
Import-Module ./src/PartnerAppDeploy.psm1
$cfg = Import-DeployerConfig ./config/deployer.json
Connect-Deployer -PartnerTenantId $cfg.partnerTenantId -ClientId $cfg.clientId
Get-DeployerTokenClaims -TenantId <tenant-id> | Select-Object scp, wids, upn
```

`scp` lists the deployer's consented scopes in that tenant. `wids` lists the Entra role template IDs your GDAP access gives you there (Cloud Application Administrator = `158c047a-c907-4556-b7ef-446551a6b5f7`).
