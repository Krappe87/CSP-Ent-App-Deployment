#Requires -Version 7.2
<#
    PartnerAppDeploy.psm1

    Shared helpers for mass-deploying multi-tenant enterprise apps into GDAP customer tenants
    from a Microsoft CSP partner tenant.

    The flow (see README.md for the full explanation):
      1. A partner admin signs in once, with MFA, to the "deployer" app registered in the partner tenant.
      2. The Partner Center applicationconsents API pre-consents the deployer app into a customer tenant.
         Microsoft only lets you do this for an app you own, which is why the vendor app can't be pushed directly.
      3. The admin's refresh token is exchanged for a Microsoft Graph token in that customer tenant
         (allowed because of GDAP + step 2). Graph then creates the vendor app's service principal
         and grants tenant-wide consent, the same end state as a Global Admin clicking "Accept".

    No secrets are stored: the deployer is a public client and tokens live only in memory.
#>

$script:GraphAppId       = '00000003-0000-0000-c000-000000000000'
$script:GraphApi         = 'https://graph.microsoft.com'
$script:PartnerCenterApi = 'https://api.partnercenter.microsoft.com'
$script:LoginHost        = 'https://login.microsoftonline.com'
$script:Session          = $null

#region Utilities

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-JwtPayload {
    param([Parameter(Mandatory)][string]$Token)
    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function ConvertFrom-QueryString {
    param([string]$Query)
    $result = @{}
    foreach ($pair in $Query.TrimStart('?', '#').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $key, $value = $pair.Split('=', 2)
        $result[[uri]::UnescapeDataString($key)] = if ($null -ne $value) { [uri]::UnescapeDataString($value.Replace('+', ' ')) } else { '' }
    }
    $result
}

function Test-Guid {
    param([string]$Value)
    $parsed = [guid]::Empty
    [guid]::TryParse($Value, [ref]$parsed)
}

# Pulls a readable message out of Graph, Partner Center or Entra token-endpoint error bodies.
function Get-ApiErrorMessage {
    param($Body)
    if ($null -eq $Body -or $Body -eq '') { return '(empty response body)' }
    if ($Body -is [string]) { return $Body }
    if ($Body.error.message) { return "$($Body.error.code): $($Body.error.message)" }          # Microsoft Graph
    if ($Body.error_description) { return ($Body.error_description -split "`r?`n")[0] }       # Entra token endpoint
    if ($Body.description) { return "$($Body.code): $($Body.description)" }                   # Partner Center
    if ($Body.message) { return $Body.message }
    ConvertTo-Json -InputObject $Body -Depth 5 -Compress
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$Attempts = 5,
        [int]$DelaySeconds = 5,
        [string]$Activity = 'Operation'
    )
    for ($i = 1; ; $i++) {
        try { return & $ScriptBlock }
        catch {
            if ($i -ge $Attempts) { throw }
            Write-Verbose "$Activity failed (attempt $i/$Attempts), retrying in $DelaySeconds s: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# Maps common failures to a plain-English next step for the report.
function Get-FailureHint {
    param([string]$Message)
    switch -Regex ($Message) {
        'AADSTS90099' { return 'The deployer app is not consented in this tenant yet. Run again without -SkipDeployerConsent and check for a Partner Center error.' }
        'AADSTS50020|AADSTS90072|AADSTS50034' { return 'Your account has no access to this tenant. The GDAP relationship may have expired, or your user is not in a GDAP security group for this customer.' }
        'AADSTS50076|AADSTS50079|AADSTS53003|AADSTS50158' { return 'Conditional Access in the customer tenant is blocking your partner sign-in (MFA, device or location rule). Check CA policies that target service provider users.' }
        'AADSTS65001|AADSTS650052' { return 'The deployer app is missing consent in this tenant. Run again; if it keeps failing, remove the deployer consent in Partner Center and retry.' }
        'AADSTS700016' { return 'The deployer app was not found. Make sure it is multi-tenant (run New-DeployerApp.ps1 again).' }
        'Authorization_RequestDenied|Insufficient privileges' { return 'Your GDAP roles in this tenant are not enough. You need Cloud Application Administrator or Application Administrator (Privileged Role Administrator for Graph application permissions).' }
        'Partner Center.*HTTP 401' { return 'Partner Center rejected the token. Sign in again with MFA, and check the deployer app has Partner Center user_impersonation consented in your partner tenant.' }
        'Partner Center.*HTTP 403' { return 'Partner Center refused the consent call. You must be in the AdminAgents group and hold Cloud Application Administrator or Application Administrator through GDAP for this customer.' }
        'Partner Center.*HTTP 404' { return 'Partner Center does not recognise this customer ID. See docs/TROUBLESHOOTING.md (GDAP-only customers).' }
        'does not reference a valid application object|NoBackingApplicationObject' { return 'The target appId was not found. Check appId in the app profile (config/apps). The vendor app must be multi-tenant.' }
        default { return '' }
    }
}

#endregion

#region Sign-in and tokens

function Invoke-TokenRequest {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][hashtable]$Form)
    $response = Invoke-RestMethod -Method Post -Uri "$script:LoginHost/$TenantId/oauth2/v2.0/token" -Body $Form `
        -SkipHttpErrorCheck -StatusCodeVariable status
    if ($status -ne 200) { throw "Token request for tenant $TenantId failed: $(Get-ApiErrorMessage $response)" }
    $response
}

function Send-ListenerResponse {
    param($Context, [string]$Message)
    $html = "<html><body style='font-family:Segoe UI,sans-serif;padding:2em'><h3>$Message</h3></body></html>"
    $bytes = [Text.Encoding]::UTF8.GetBytes($html)
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

# Authorization code + PKCE through the system browser and a one-shot loopback listener.
function Invoke-BrowserSignIn {
    param([string]$TenantId, [string]$ClientId, [string]$Scope, [string]$LoginHint, [int]$TimeoutSeconds = 300)

    $verifier  = ConvertTo-Base64Url ([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state     = [guid]::NewGuid().ToString('N')

    # Entra ignores the port when matching the registered http://localhost redirect URI, so any free port works.
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
    $redirectUri = "http://localhost:$port"

    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("$redirectUri/")
    $listener.Start()
    try {
        $query = [ordered]@{
            client_id             = $ClientId
            response_type         = 'code'
            response_mode         = 'query'
            redirect_uri          = $redirectUri
            scope                 = $Scope
            state                 = $state
            code_challenge        = $challenge
            code_challenge_method = 'S256'
            prompt                = 'select_account'
        }
        if ($LoginHint) { $query.login_hint = $LoginHint }
        $pairs = foreach ($entry in $query.GetEnumerator()) { '{0}={1}' -f $entry.Key, [uri]::EscapeDataString($entry.Value) }
        $authorizeUrl = "$script:LoginHost/$TenantId/oauth2/v2.0/authorize?" + ($pairs -join '&')

        Write-Host 'Opening your browser to sign in to the PARTNER tenant (complete MFA)...' -ForegroundColor Cyan
        Write-Host "If no browser opens, paste this URL into one:`n$authorizeUrl" -ForegroundColor DarkGray
        Start-Process $authorizeUrl

        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($true) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.Wait(500)) {
                if ([DateTime]::UtcNow -gt $deadline) { throw "Timed out after $TimeoutSeconds seconds waiting for browser sign-in." }
            }
            $context = $pending.Result
            $params = ConvertFrom-QueryString $context.Request.Url.Query
            if (-not ($params.ContainsKey('code') -or $params.ContainsKey('error'))) {
                $context.Response.StatusCode = 404
                $context.Response.Close()
                continue
            }
            $ok = $params.ContainsKey('code') -and $params.state -eq $state
            Send-ListenerResponse $context ($ok ? 'Signed in. You can close this tab and go back to PowerShell.' : 'Sign-in failed. Go back to PowerShell for details.')
            break
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }

    if ($params.error) { throw "Sign-in failed: $($params.error) - $($params.error_description)" }
    if ($params.state -ne $state) { throw 'Sign-in response state did not match the request. Aborting.' }

    Invoke-TokenRequest -TenantId $TenantId -Form @{
        client_id     = $ClientId
        grant_type    = 'authorization_code'
        code          = $params.code
        redirect_uri  = $redirectUri
        code_verifier = $verifier
        scope         = $Scope
    }
}

# Device code flow, for machines without a usable browser. Often blocked by Conditional Access.
function Invoke-DeviceCodeSignIn {
    param([string]$TenantId, [string]$ClientId, [string]$Scope)

    $device = Invoke-RestMethod -Method Post -Uri "$script:LoginHost/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = $Scope } -SkipHttpErrorCheck -StatusCodeVariable status
    if ($status -ne 200) { throw "Device code request failed: $(Get-ApiErrorMessage $device)" }
    Write-Host $device.message -ForegroundColor Yellow

    $interval = [int]$device.interval
    $deadline = [DateTime]::UtcNow.AddSeconds([int]$device.expires_in)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $response = Invoke-RestMethod -Method Post -Uri "$script:LoginHost/$TenantId/oauth2/v2.0/token" -SkipHttpErrorCheck -StatusCodeVariable status -Body @{
            client_id   = $ClientId
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = $device.device_code
        }
        if ($status -eq 200) { return $response }
        switch ($response.error) {
            'authorization_pending' { }
            'slow_down' { $interval += 5 }
            default { throw "Device code sign-in failed: $(Get-ApiErrorMessage $response)" }
        }
    }
    throw 'The device code expired before sign-in finished.'
}

function Save-DeployerToken {
    param([string]$TenantId, [string]$Api, $Response)
    $script:Session.Tokens["$TenantId|$Api"] = @{
        AccessToken = $Response.access_token
        ExpiresOn   = [DateTime]::UtcNow.AddSeconds([int]$Response.expires_in)
    }
}

function Assert-DeployerSession {
    if (-not $script:Session) { throw 'Not signed in. Call Connect-Deployer first.' }
}

function Connect-Deployer {
    <#
    .SYNOPSIS
        Interactive partner-admin sign-in to the deployer app. Keeps the refresh token in memory only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartnerTenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [switch]$UseDeviceCode,
        [string]$LoginHint
    )
    $scope = "$script:GraphApi/.default offline_access openid profile"
    $response = if ($UseDeviceCode) {
        Invoke-DeviceCodeSignIn -TenantId $PartnerTenantId -ClientId $ClientId -Scope $scope
    } else {
        Invoke-BrowserSignIn -TenantId $PartnerTenantId -ClientId $ClientId -Scope $scope -LoginHint $LoginHint
    }
    if (-not $response.refresh_token) { throw 'No refresh token was returned. Make sure offline_access is consented on the deployer app.' }

    $claims = ConvertFrom-JwtPayload $response.access_token
    if ((Test-Guid $PartnerTenantId) -and $claims.tid -ne $PartnerTenantId) {
        throw "You signed in to tenant $($claims.tid), but the deployer lives in partner tenant $PartnerTenantId. Sign in with a partner account."
    }

    $script:Session = [pscustomobject]@{
        PartnerTenantId = $claims.tid
        ClientId        = $ClientId
        Account         = $claims.upn ?? $claims.unique_name ?? $claims.preferred_username
        RefreshToken    = $response.refresh_token
        Tokens          = @{}
    }
    Save-DeployerToken -TenantId $claims.tid -Api 'Graph' -Response $response

    Write-Host "Signed in as $($script:Session.Account)" -ForegroundColor Green
    if ('mfa' -notin @($claims.amr)) {
        Write-Warning 'This sign-in has no MFA claim. Partner Center and GDAP access both expect MFA, so later calls may fail.'
    }
    $script:Session | Select-Object PartnerTenantId, ClientId, Account
}

function Get-DeployerSession {
    Assert-DeployerSession
    $script:Session | Select-Object PartnerTenantId, ClientId, Account
}

function Get-DeployerToken {
    <#
    .SYNOPSIS
        Returns an access token for Graph or Partner Center in any tenant, by redeeming the partner
        admin's refresh token against that tenant. Customer tenants work through GDAP once the
        deployer app is consented there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [ValidateSet('Graph', 'PartnerCenter')][string]$Api = 'Graph',
        [switch]$ForceRefresh
    )
    Assert-DeployerSession
    $cached = $script:Session.Tokens["$TenantId|$Api"]
    if (-not $ForceRefresh -and $cached -and $cached.ExpiresOn -gt [DateTime]::UtcNow.AddMinutes(5)) { return $cached.AccessToken }

    $resource = if ($Api -eq 'Graph') { $script:GraphApi } else { $script:PartnerCenterApi }
    $response = Invoke-TokenRequest -TenantId $TenantId -Form @{
        client_id     = $script:Session.ClientId
        grant_type    = 'refresh_token'
        refresh_token = $script:Session.RefreshToken
        scope         = "$resource/.default offline_access"
    }
    # Keep the partner-tenant refresh token fresh; it is the one every customer token is derived from.
    if ($TenantId -eq $script:Session.PartnerTenantId -and $response.refresh_token) { $script:Session.RefreshToken = $response.refresh_token }
    Save-DeployerToken -TenantId $TenantId -Api $Api -Response $response
    $response.access_token
}

function Get-DeployerTokenClaims {
    param([Parameter(Mandatory)][string]$TenantId, [ValidateSet('Graph', 'PartnerCenter')][string]$Api = 'Graph')
    ConvertFrom-JwtPayload (Get-DeployerToken -TenantId $TenantId -Api $Api)
}

#endregion

#region HTTP

function Invoke-DeployerRequest {
    <#
    .SYNOPSIS
        Sends an authenticated request and returns status + body without throwing on HTTP errors.
        Retries throttling (429) and transient 5xx responses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$TenantId,
        [ValidateSet('Graph', 'PartnerCenter')][string]$Api = 'Graph',
        [object]$Body,
        [hashtable]$Headers = @{},
        [int]$MaxRetries = 4
    )
    for ($attempt = 1; ; $attempt++) {
        $request = @{
            Method                  = $Method
            Uri                     = $Uri
            Headers                 = @{ Authorization = "Bearer $(Get-DeployerToken -TenantId $TenantId -Api $Api)"; Accept = 'application/json' } + $Headers
            SkipHttpErrorCheck      = $true
            StatusCodeVariable      = 'status'
            ResponseHeadersVariable = 'responseHeaders'
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $request.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
            $request.ContentType = 'application/json'
        }
        $response = Invoke-RestMethod @request

        if (($status -eq 429 -or $status -ge 500) -and $attempt -le $MaxRetries) {
            $delay = [int][math]::Min(60, 2 * [math]::Pow(2, $attempt))
            $retryAfter = $responseHeaders.Keys | Where-Object { $_ -eq 'Retry-After' } | ForEach-Object { $responseHeaders[$_] } | Select-Object -First 1
            $parsed = 0
            if ($retryAfter -and [int]::TryParse($retryAfter, [ref]$parsed)) { $delay = $parsed }
            Write-Verbose "HTTP $status from $Method $Uri. Retrying in $delay s ($attempt/$MaxRetries)."
            Start-Sleep -Seconds $delay
            continue
        }
        return [pscustomobject]@{
            StatusCode = [int]$status
            Body       = $response
            IsSuccess  = $status -ge 200 -and $status -lt 300
        }
    }
}

function Invoke-Graph {
    <#
    .SYNOPSIS
        Microsoft Graph v1.0 call in the given tenant. Returns the body; throws on HTTP errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [object]$Body,
        [hashtable]$Headers = @{}
    )
    $request = @{
        Method   = $Method
        Uri      = ($Path -like 'https://*') ? $Path : "$script:GraphApi/v1.0$Path"
        TenantId = $TenantId
        Api      = 'Graph'
        Headers  = $Headers
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = $Body }
    $response = Invoke-DeployerRequest @request
    if (-not $response.IsSuccess) {
        throw "Graph $Method $($Path -replace '\?.*$', '') failed (HTTP $($response.StatusCode)) - $(Get-ApiErrorMessage $response.Body)"
    }
    $response.Body
}

function Get-GraphCollection {
    <#
    .SYNOPSIS
        GETs a Graph collection and follows @odata.nextLink, emitting every item.
    #>
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$Path, [hashtable]$Headers = @{})
    $next = $Path
    while ($next) {
        $page = Invoke-Graph -TenantId $TenantId -Path $next -Headers $Headers
        $page.value
        $next = $page.'@odata.nextLink'
    }
}

function Get-ServicePrincipalByAppId {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AppId,
        [string]$Select = 'id,appId,displayName,appRoleAssignmentRequired,accountEnabled'
    )
    $result = Invoke-Graph -TenantId $TenantId -Path "/servicePrincipals?`$filter=appId eq '$AppId'&`$select=$Select"
    @($result.value) | Select-Object -First 1
}

#endregion

#region Partner Center

function Get-GdapCustomer {
    <#
    .SYNOPSIS
        Lists customers that have a GDAP relationship with the partner tenant.
    #>
    Assert-DeployerSession
    Get-GraphCollection -TenantId $script:Session.PartnerTenantId -Path '/tenantRelationships/delegatedAdminCustomers' |
        ForEach-Object { [pscustomobject]@{ TenantId = $_.tenantId ?? $_.id; Name = $_.displayName } } |
        Sort-Object Name
}

function Grant-DeployerConsent {
    <#
    .SYNOPSIS
        Pre-consents the deployer app into a customer tenant through the Partner Center
        applicationconsents API. Returns 'Granted' or 'AlreadyPresent'.
    .NOTES
        Caller needs: AdminAgents membership in the partner tenant, plus Cloud Application Administrator
        or Application Administrator in the customer tenant through GDAP.
    #>
    param([Parameter(Mandatory)][string]$CustomerTenantId, [Parameter(Mandatory)][string[]]$GraphScopes)
    Assert-DeployerSession
    $body = @{
        applicationId     = $script:Session.ClientId
        applicationGrants = @(@{ enterpriseApplicationId = $script:GraphAppId; scope = $GraphScopes -join ',' })
    }
    $response = Invoke-DeployerRequest -Method POST -Api PartnerCenter -TenantId $script:Session.PartnerTenantId -Body $body `
        -Uri "$script:PartnerCenterApi/v1/customers/$CustomerTenantId/applicationconsents"
    if ($response.IsSuccess) { return 'Granted' }
    $message = Get-ApiErrorMessage $response.Body
    if ($response.StatusCode -eq 409 -or $message -match 'already exists') { return 'AlreadyPresent' }
    throw "Partner Center consent failed (HTTP $($response.StatusCode)) - $message"
}

function Remove-DeployerConsent {
    <#
    .SYNOPSIS
        Removes the deployer app's consent (and its enterprise app) from a customer tenant.
        Returns 'Removed' or 'NotPresent'.
    #>
    param([Parameter(Mandatory)][string]$CustomerTenantId)
    Assert-DeployerSession
    $response = Invoke-DeployerRequest -Method DELETE -Api PartnerCenter -TenantId $script:Session.PartnerTenantId `
        -Uri "$script:PartnerCenterApi/v1/customers/$CustomerTenantId/applicationconsents/$($script:Session.ClientId)"
    if ($response.IsSuccess) { return 'Removed' }
    if ($response.StatusCode -eq 404) { return 'NotPresent' }
    throw "Partner Center consent removal failed (HTTP $($response.StatusCode)) - $(Get-ApiErrorMessage $response.Body)"
}

function Wait-DeployerTenantAccess {
    <#
    .SYNOPSIS
        Gets a Graph token in the customer tenant and reports which required scopes it lacks.
        Use -Attempts > 1 right after granting consent, which takes a little while to replicate.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string[]]$RequiredScopes,
        [int]$Attempts = 1,
        [int]$DelaySeconds = 10
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $null = Get-DeployerToken -TenantId $TenantId -Api Graph -ForceRefresh
            $granted = @((Get-DeployerTokenClaims -TenantId $TenantId).scp -split ' ')
            $missing = @($RequiredScopes | Where-Object { $_ -notin $granted })
            if ($missing.Count -eq 0 -or $i -ge $Attempts) {
                return [pscustomobject]@{ GrantedScopes = $granted; MissingScopes = $missing }
            }
            Write-Verbose "Token for $TenantId is missing $($missing -join ', '); waiting for consent to replicate ($i/$Attempts)."
        } catch {
            if ($i -ge $Attempts) { throw }
            Write-Verbose "No access to $TenantId yet ($i/$Attempts): $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $DelaySeconds
    }
}

#endregion

#region Config files

function Import-DeployerConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Deployer config not found at $Path. Run scripts/New-DeployerApp.ps1 first." }
    $config = Get-Content $Path -Raw | ConvertFrom-Json
    foreach ($field in 'partnerTenantId', 'clientId', 'customerGraphScopes') {
        if (-not $config.$field) { throw "Deployer config $Path is missing '$field'. Run scripts/New-DeployerApp.ps1 again." }
    }
    $config
}

function Import-TargetAppProfile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Target app profile not found at $Path. Run scripts/New-TargetAppProfile.ps1, or copy config/app-profile.example.json and fill it in."
    }
    $target = Get-Content $Path -Raw | ConvertFrom-Json
    foreach ($list in 'delegatedPermissions', 'applicationPermissions') {
        if ($null -eq $target.$list) { $target | Add-Member -NotePropertyName $list -NotePropertyValue @() -Force }
    }
    if (-not (Test-Guid $target.appId) -or [guid]$target.appId -eq [guid]::Empty) {
        throw "appId in $Path is missing or still the placeholder. See docs/SETUP.md, step 6."
    }
    if (-not $target.displayName) { $target | Add-Member -NotePropertyName displayName -NotePropertyValue $target.appId -Force }
    if (@($target.delegatedPermissions).Count + @($target.applicationPermissions).Count -eq 0) {
        throw "$Path lists no permissions to consent."
    }
    foreach ($perm in $target.delegatedPermissions) {
        if (-not (Test-Guid $perm.resourceAppId) -or @($perm.scopes).Count -eq 0) { throw "Every delegatedPermissions entry in $Path needs a resourceAppId and scopes." }
    }
    foreach ($perm in $target.applicationPermissions) {
        if (-not (Test-Guid $perm.resourceAppId) -or @($perm.roles).Count -eq 0) { throw "Every applicationPermissions entry in $Path needs a resourceAppId and roles." }
    }
    $target
}

#endregion

Export-ModuleMember -Function @(
    'ConvertFrom-JwtPayload', 'ConvertFrom-QueryString', 'Test-Guid', 'Get-ApiErrorMessage', 'Invoke-WithRetry', 'Get-FailureHint',
    'Connect-Deployer', 'Get-DeployerSession', 'Get-DeployerToken', 'Get-DeployerTokenClaims',
    'Invoke-DeployerRequest', 'Invoke-Graph', 'Get-GraphCollection', 'Get-ServicePrincipalByAppId',
    'Get-GdapCustomer', 'Grant-DeployerConsent', 'Remove-DeployerConsent', 'Wait-DeployerTenantAccess',
    'Import-DeployerConfig', 'Import-TargetAppProfile'
)
