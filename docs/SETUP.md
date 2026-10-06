# Setup (one-time)

Work through these steps once. After that, a rollout is a single command (see [RUNBOOK.md](RUNBOOK.md)).

| Step | What | Who / where |
|---|---|---|
| 1 | Check GDAP roles | Partner Center |
| 2 | Check the partner user who will run rollouts | Partner tenant |
| 3 | Install PowerShell 7 and one Graph module | Your workstation |
| 4 | Create the deployer app | Partner Global Admin |
| 5 | Check GDAP readiness with the script | You |
| 6 | Build a profile for each app you want to deploy | You |

---

## 1. Check GDAP roles

Microsoft only lets the consent API run when **your partner user** holds, through GDAP in that customer, at least one of these roles:

- **Cloud Application Administrator** (recommended: narrowest role that works)
- **Application Administrator**

The same role also allows creating the enterprise app and granting its delegated consent.

A role has to be **in the GDAP relationship** and **assigned to a security group** in that relationship, and your user has to be **a member of that group**.

**How to check one customer by hand:** Partner Center → *Customers* → pick the customer → *Admin relationships* → open the active relationship. Look at *Microsoft Entra roles* and *Security groups*.

**How to check all customers at once:** after step 4, run `scripts/Test-GdapReadiness.ps1` (step 5).

**If a customer's relationship doesn't include one of those roles:** you can't add a role to an existing GDAP relationship. You have two options:

- **Add a second, short relationship (Microsoft's recommendation).** Create a new GDAP relationship that contains only *Cloud Application Administrator* and lasts 1 day or longer. Send the approval link to the customer's Global Admin. Once it's approved, assign the role to your security group and run the deployment. You can let it expire or end it afterwards.
- **Fold it into your standard template.** Add *Cloud Application Administrator* to the GDAP template you use for new clients, so future onboardings are covered automatically.

> Approving a GDAP relationship is still a one-time click for each customer's admin. Once the role is in place, though, this deployment and any future multi-tenant app need no client involvement at all.

**Application permissions.** If an app needs Microsoft Graph *application* permissions, Cloud Application Administrator isn't enough. You'd also need **Privileged Role Administrator**, and the deployer must be created with `-IncludeAppRoleAssignment`. Typical "Sign in with Microsoft" apps only use delegated sign-in scopes, so this usually doesn't apply.

## 2. Check the partner user who will run rollouts

- The user is a member of **AdminAgents** in your partner tenant. In Partner Center this shows as the *Admin agent* role. Every Partner Center API call requires it.
- The user signs in with **MFA**. Partner Center rejects tokens without an MFA claim.
- The user is in the GDAP security group(s) from step 1.

## 3. Install the tooling

```powershell
winget install --id Microsoft.PowerShell --source winget     # PowerShell 7, if you don't already have it
pwsh                                                         # run everything below in PowerShell 7
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

`Microsoft.Graph.Authentication` is only used by step 4. The rollout scripts call the REST APIs directly and have no module dependencies.

If script execution is blocked, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or `Unblock-File` the downloaded `.ps1` / `.psm1` files.

## 4. Create the deployer app

The deployer is a small app registration in **your partner tenant**. Partner Center can only pre-consent apps you own, so this app is the bridge into each customer tenant.

### Option A: script (recommended)

Run this as a Global Administrator of the **partner** tenant:

```powershell
./scripts/New-DeployerApp.ps1 -PartnerTenantId yourmsp.onmicrosoft.com
```

It creates (or updates) **MSP Enterprise App Deployer**, grants admin consent for it in your partner tenant, and writes `config/deployer.json`. It's safe to run again.

### Option B: by hand in the Entra admin center

1. **App registrations → New registration**
   - Name: `MSP Enterprise App Deployer`
   - Supported account types: **Accounts in any organizational directory (Multitenant)**
   - Redirect URI: platform **Public client/native (mobile & desktop)**, value `http://localhost`
2. **Authentication → Advanced settings → Allow public client flows: Yes.** Save.
3. **API permissions → Add a permission**
   - *Microsoft Graph → Delegated*: `Application.ReadWrite.All`, `DelegatedPermissionGrant.ReadWrite.All`, `DelegatedAdminRelationship.Read.All`, `offline_access`, `openid`, `profile`
   - *APIs my organization uses →* search **Microsoft Partner Center** *→ Delegated*: `user_impersonation`
4. Click **Grant admin consent for \<your partner tenant\>**.
5. Create `config/deployer.json`:

```json
{
  "partnerTenantId": "<your partner tenant ID>",
  "clientId": "<the app's Application (client) ID>",
  "displayName": "MSP Enterprise App Deployer",
  "customerGraphScopes": [ "Application.ReadWrite.All", "DelegatedPermissionGrant.ReadWrite.All" ]
}
```

No client secret or certificate is needed. Don't add one.

## 5. Check GDAP readiness

```powershell
./scripts/Test-GdapReadiness.ps1
```

This signs you in through the deployer app and lists every customer with one of these statuses:

| Status | Meaning |
|---|---|
| **Ready** | A consent role is in the relationship and assigned to a group. Make sure you're in that group. |
| **Role in relationship but not assigned to a group** | In Partner Center, assign the role to your security group in that relationship. |
| **Global Admin only** | Should work, but isn't on Microsoft's confirmed list for the consent API. Try it on one tenant. |
| **Needs Cloud Application Administrator** | See step 1: add a short secondary GDAP relationship. |

## 6. Build a profile for each app

Each app you want to deploy gets a small JSON profile in `config/apps/`. The rollout deploys every profile in that folder by default. A profile holds two facts about the vendor's app: its **Application (client) ID**, and **which permissions** it asks users for. Most vendors don't publish these, so collect them in one of three ways.

### Option A: from the app's sign-in URL (no tenant access needed)

1. Open the vendor app's login page in a private/InPrivate window.
2. Click its **Sign in with Microsoft** button (or *Login with Microsoft*, *Continue with Microsoft*, and so on).
3. When the Microsoft sign-in page appears, **don't sign in**. Copy the whole URL from the address bar.
   - If that URL has no `client_id=` in it, press **F12 → Network**, click the sign-in button again, filter for `authorize`, and copy that request's URL instead.
4. Run:

```powershell
./scripts/New-TargetAppProfile.ps1 -DisplayName 'Contoso Portal' -LoginUrl '<paste the URL here>'
```

This writes `config/apps/contoso-portal.json`. The script reads `client_id` and `scope` from the URL. If the app requests `.default` (its pre-registered permission set), the URL won't list the scopes, and the script will tell you to use option B or C instead.

### Option B: copy from a tenant where consent was already accepted (most accurate)

If you've already set the app up by hand for any customer, or for your own tenant, read it from there:

```powershell
./scripts/New-TargetAppProfile.ps1 -ReferenceTenantId <that tenant's ID> -DisplayName 'Contoso'
# More than one enterprise app matched? Use the app ID from the table it prints:
./scripts/New-TargetAppProfile.ps1 -ReferenceTenantId <tenant ID> -AppId <app ID>
```

`-DisplayName` here is search text for the tenant's enterprise apps. This option copies exactly what a Global Admin approved, including any non-Graph APIs and application permissions.

### Option C: by hand

In a tenant where the app exists: **Entra admin center → Enterprise applications →** search for the app (clear the *Application type* filter). Copy the **Application ID** from *Overview*, and the granted permissions from *Permissions*. Then run:

```powershell
./scripts/New-TargetAppProfile.ps1 -DisplayName 'Contoso Portal' -AppId <Application ID> -GraphScope openid, profile, email, User.Read
```

(or copy `config/app-profile.example.json` to `config/apps/<name>.json` and edit it).

### Check the result

Each profile should look like this:

```json
{
  "displayName": "Contoso Portal",
  "appId": "<the vendor app's client ID>",
  "delegatedPermissions": [
    { "resourceAppId": "00000003-0000-0000-c000-000000000000", "resourceName": "Microsoft Graph",
      "scopes": [ "openid", "profile", "email", "User.Read" ] }
  ],
  "applicationPermissions": [],
  "userAssignmentRequired": false
}
```

- `scopes` must include **every** scope the app requests at sign-in. If one is missing, users will still get a consent prompt, or *Need admin approval* if user consent is disabled.
- `applicationPermissions` lists Graph (or other API) app roles, e.g. `{ "resourceAppId": "00000003-0000-0000-c000-000000000000", "resourceName": "Microsoft Graph", "roles": [ "User.Read.All" ] }`. These need the extra setup described in step 1.
- `userAssignmentRequired: false` means every user in the tenant can sign in to the app. Set it to `true` to control access per user or group in each tenant. Remove the field entirely to leave each tenant's setting untouched.
- To stop deploying an app, move its profile out of `config/apps/`. Deployments that already happened are left in place.

You're done with setup. Continue with [RUNBOOK.md](RUNBOOK.md).
