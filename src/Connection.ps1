<#
    X-TAP Sharing Migration - connections and Microsoft Graph calls.

    - Exchange Online (ExchangeOnlineManagement): read-only, used by -Mode Collect only.
    - Microsoft Graph (Microsoft.Graph.Authentication, Invoke-MgGraphRequest): every call goes to
      https://graph.microsoft.com/v1.0. The beta endpoint and the beta Graph modules are
      never used.

    The two modules ship their own copy of MSAL (Microsoft.Identity.Client). PowerShell 7 loads one copy
    per session: the module with the most recent MSAL is imported first, so the other one finds a
    version at least as recent as the one it was built with.

    All Graph calls go through Invoke-XsmGraph. The tests replace it with an in-memory tenant by
    setting $script:GraphInvoker (scriptblock: param($Method, $Uri, $Body)).
#>

# ExchangeOnlineManagement versions that must not be used, by authentication mode (checked in the lab).
$script:ExoKnownIssues = @{
    '3.10.0' = @{ Modes = @('Certificate'); Issue = 'its certificate authentication fails with "Object reference not set to an instance of an object" (fixed in 3.10.1)' }
}
$script:ModuleRequirements = @{
    ExchangeOnlineManagement         = @{ Minimum = [version]'3.9.0'; Install = 'Install-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -Scope CurrentUser' }
    'Microsoft.Graph.Authentication' = @{ Minimum = [version]'2.25.0'; Install = 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
}
$script:GraphInvoker = $null
$script:ConsumerTenantId = '9188040d-6c67-4c5b-b112-36a304b66dad'

function Select-XsmModule {
    <#
    .SYNOPSIS
        Chooses the version of a module: the version already loaded in the session, otherwise the most
        recent installed version that meets the minimum and has no known issue for the authentication mode.
    #>
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][object[]]$Available, [AllowNull()]$Loaded, [string]$Mode = 'Interactive')
    $req = $script:ModuleRequirements[$Name]
    $problem = {
        param($Version)
        if ($Version -lt $req.Minimum) { return "it is older than $($req.Minimum)" }
        if ($Name -eq 'ExchangeOnlineManagement') {
            $known = $script:ExoKnownIssues[$Version.ToString()]
            if ($known -and $Mode -in $known.Modes) { return $known.Issue }
        }
    }
    if ($Loaded) {
        $why = & $problem $Loaded.Version
        if ($why) { throw "$Name $($Loaded.Version) is already loaded in this PowerShell session and cannot be used: $why. Open a new PowerShell window. If this version is loaded automatically, run: $($req.Install)" }
        return [pscustomobject]@{ Module = $Loaded; Skipped = @() }
    }
    $sorted = @($Available | Where-Object { $_ } | Sort-Object Version -Descending)
    if (-not $sorted.Count) { throw "The $Name module is not installed. Run: $($req.Install)" }
    $skipped = [Collections.Generic.List[string]]::new()
    foreach ($m in $sorted) {
        $why = & $problem $m.Version
        if (-not $why) { return [pscustomobject]@{ Module = $m; Skipped = @($skipped) } }
        if (-not $skipped.Contains("$($m.Version): $why")) { $skipped.Add("$($m.Version): $why") }
    }
    throw "No usable $Name version is installed. $(@($skipped) -join '; '). Run: $($req.Install)"
}

function Get-XsmMsalVersion {
    <# Most recent Microsoft.Identity.Client.dll shipped in a module folder (0.0 when none). #>
    param([Parameter(Mandatory)][string]$ModuleBase)
    $versions = @(Get-ChildItem -LiteralPath $ModuleBase -Recurse -Filter 'Microsoft.Identity.Client.dll' -File -ErrorAction SilentlyContinue |
        ForEach-Object { try { [version]$_.VersionInfo.FileVersion } catch { $null } } | Where-Object { $_ })
    if (-not $versions.Count) { return [version]'0.0' }
    return ($versions | Sort-Object -Descending | Select-Object -First 1)
}

function Import-XsmModules {
    <#
    .SYNOPSIS
        Imports Microsoft.Graph.Authentication and/or ExchangeOnlineManagement, the one with the most
        recent MSAL first. Returns the versions used.
    #>
    param([switch]$Graph, [switch]$Exchange, [string]$Mode = 'Interactive')
    $names = @(if ($Graph) { 'Microsoft.Graph.Authentication' }; if ($Exchange) { 'ExchangeOnlineManagement' })
    $choices = foreach ($name in $names) {
        $choice = Select-XsmModule -Name $name -Available @(Get-Module $name -ListAvailable) -Loaded (Get-Module $name | Select-Object -First 1) -Mode $Mode
        foreach ($s in $choice.Skipped) { Write-XsmItem Info "$name $s - skipped, $($choice.Module.Version) used." }
        [pscustomobject]@{ Name = $name; Module = $choice.Module; Msal = Get-XsmMsalVersion $choice.Module.ModuleBase; Loaded = [bool](Get-Module $name) }
    }
    foreach ($c in @($choices | Sort-Object @{ Expression = { $_.Loaded }; Descending = $true }, @{ Expression = { $_.Msal }; Descending = $true })) {
        if (-not $c.Loaded) { Import-Module $c.Module -Global -WarningAction SilentlyContinue }
        Write-XsmLog 'INFO' "$($c.Name) $($c.Module.Version), MSAL $($c.Msal) ($($c.Module.ModuleBase))"
    }
    $result = [ordered]@{}
    foreach ($c in $choices) { $result[$c.Name] = $c.Module.Version.ToString() }
    return $result
}

# ---------------------------------------------------------------------------------------------------
# Exchange Online
# ---------------------------------------------------------------------------------------------------
$script:ExoCommands = @(
    'Get-OrganizationRelationship', 'Get-AvailabilityAddressSpace', 'Get-SharingPolicy', 'Get-AcceptedDomain',
    'Get-OrganizationConfig', 'Get-OnPremisesOrganization', 'Get-IntraOrganizationConnector', 'Get-Recipient', 'Get-Group'
)

function Connect-XsmExchange {
    <#
    .SYNOPSIS
        Connects to Exchange Online (read-only use) and checks the tenant and the account.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [string]$ExpectedAccount)
    $auth = $Settings.Authentication
    $prefix = $script:ExoPrefix
    $existing = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.ModulePrefix -eq $prefix -and $_.State -eq 'Connected' })
    $connectedHere = $false
    if (-not $existing) {
        $parameters = @{ Prefix = $prefix; ShowBanner = $false; CommandName = $script:ExoCommands; ErrorAction = 'Stop' }
        switch ($auth.Mode) {
            'Certificate' { $parameters.AppId = $auth.AppId; $parameters.CertificateThumbprint = $auth.CertificateThumbprint; $parameters.Organization = $Settings.Tenant.Organization }
            'DeviceCode' { $parameters.Device = $true }
            default {
                if ($ExpectedAccount) { $parameters.UserPrincipalName = $ExpectedAccount }
                if ($auth.DisableWAM -and (Get-Command Connect-ExchangeOnline).Parameters.ContainsKey('DisableWAM')) { $parameters.DisableWAM = $true }
            }
        }
        Connect-ExchangeOnline @parameters | Out-Null
        $connectedHere = $true
    }
    $connection = @(Get-ConnectionInformation | Where-Object { $_.ModulePrefix -eq $prefix -and $_.State -eq 'Connected' }) | Select-Object -Last 1
    if (-not $connection) { throw 'The Exchange Online connection was not established.' }
    $account = if ($auth.Mode -eq 'Certificate') { "app $($auth.AppId)" } else { [string]$connection.UserPrincipalName }
    $problem = $null
    if ([string]$connection.TenantID -ne $Settings.Tenant.TenantId) { $problem = "Exchange Online is connected to tenant $($connection.TenantID), but the configuration expects $($Settings.Tenant.TenantId). Sign in with an administrator of the right tenant." }
    elseif ($auth.Mode -ne 'Certificate' -and $ExpectedAccount -and $account -ine $ExpectedAccount) { $problem = "Signed in to Exchange Online as $account, but the configuration expects $ExpectedAccount." }
    if ($problem) {
        if ($connectedHere) { Disconnect-ExchangeOnline -ConnectionId $connection.ConnectionId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
        throw $problem
    }
    [pscustomobject]@{ Account = $account; TenantId = [string]$connection.TenantID; ConnectionId = $connection.ConnectionId; ConnectedHere = $connectedHere }
}

function Disconnect-XsmExchange {
    param($Connection)
    if ($Connection -and $Connection.ConnectedHere -and $Connection.ConnectionId) {
        Disconnect-ExchangeOnline -ConnectionId $Connection.ConnectionId -Confirm:$false -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
    }
}

function Invoke-XsmExchange {
    <# Calls an Exchange Online cmdlet imported with the tool prefix (Get-OrganizationRelationship -> Get-XsmExoOrganizationRelationship). #>
    param([Parameter(Mandatory)][string]$Command, [hashtable]$Parameters = @{})
    $verb, $noun = $Command.Split('-', 2)
    $name = "$verb-$($script:ExoPrefix)$noun"
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "$Command is not available in this Exchange Online session (the account may lack the permission to run it)." }
    return & $cmd @Parameters -ErrorAction Stop
}

# ---------------------------------------------------------------------------------------------------
# Microsoft Graph
# ---------------------------------------------------------------------------------------------------
function Connect-XsmGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with the delegated scopes of the current mode and phase, and checks
        the tenant and the account. An existing connection of the same account and tenant that already has
        every scope is reused.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string[]]$Scopes, [string]$ExpectedAccount)
    $auth = $Settings.Authentication
    $tenantId = $Settings.Tenant.TenantId
    $context = Get-MgContext -ErrorAction SilentlyContinue
    $reuse = $false
    if ($context -and [string]$context.TenantId -eq $tenantId) {
        if ($auth.Mode -eq 'Certificate') { $reuse = $context.AuthType -eq 'AppOnly' -and [string]$context.ClientId -eq $auth.AppId }
        else { $reuse = (-not $ExpectedAccount -or [string]$context.Account -ieq $ExpectedAccount) -and -not @($Scopes | Where-Object { $_ -notin @($context.Scopes) }).Count }
    }
    $connectedHere = $false
    if (-not $reuse) {
        if ($context) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
        $parameters = @{ TenantId = $tenantId; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
        if ($auth.Mode -eq 'Certificate') {
            $parameters.ClientId = $auth.AppId
            $parameters.CertificateThumbprint = $auth.CertificateThumbprint
        } else {
            $parameters.Scopes = $Scopes
            if ($auth.GraphClientId) { $parameters.ClientId = $auth.GraphClientId }
            if ($auth.Mode -eq 'DeviceCode') { $parameters.UseDeviceCode = $true }
            elseif ($ExpectedAccount -and (Get-Command Connect-MgGraph).Parameters.ContainsKey('LoginHint')) { $parameters.LoginHint = $ExpectedAccount }
            # Default 120 s is short for a device code with MFA: give the administrator 5 minutes.
            if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('ClientTimeout')) { $parameters.ClientTimeout = 300 }
            if ($auth.DisableWAM -and (Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue)) { Set-MgGraphOption -DisableLoginByWAM $true }
        }
        # The device code message is written to the output stream: show it, swallow the rest.
        try { Connect-MgGraph @parameters | ForEach-Object { if ($_ -is [string] -and $_ -match 'devicelogin|/device|code') { Write-XsmItem Info $_ -Icon Key } } }
        catch {
            $text = $_.Exception.Message
            if ($text -match 'window handle|WithLogging|Method not found') {
                throw "Microsoft Graph sign-in failed in this PowerShell host: $(($text -split "`n")[0]) Run the tool from Windows Terminal or the PowerShell console, or set Authentication.Mode = 'DeviceCode'."
            }
            throw
        }
        $connectedHere = $true
        $context = Get-MgContext
    }
    if (-not $context) { throw 'The Microsoft Graph connection was not established.' }
    $account = if ($context.AuthType -eq 'AppOnly') { "app $($context.ClientId)" } else { [string]$context.Account }
    $problem = $null
    if ([string]$context.TenantId -ne $tenantId) { $problem = "Microsoft Graph is connected to tenant $($context.TenantId), but the configuration expects $tenantId." }
    elseif ($auth.Mode -ne 'Certificate' -and $ExpectedAccount -and $account -ine $ExpectedAccount) { $problem = "Signed in to Microsoft Graph as $account, but the configuration expects $ExpectedAccount." }
    if ($problem) {
        if ($connectedHere) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
        throw $problem
    }
    $granted = @($context.Scopes)
    $missing = if ($context.AuthType -eq 'AppOnly') { @() } else { @($Scopes | Where-Object { $_ -notin $granted }) }
    [pscustomobject]@{ Account = $account; TenantId = [string]$context.TenantId; Scopes = $granted; MissingScopes = $missing; ConnectedHere = $connectedHere; AppName = [string]$context.AppName; AuthType = [string]$context.AuthType }
}

function Disconnect-XsmGraph {
    param($Connection)
    if ($Connection -and $Connection.ConnectedHere -and (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue)) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}

function New-XsmGraphException {
    param([int]$Status, [string]$Code, [string]$Message, [string]$Method, [string]$Uri)
    $text = "Microsoft Graph $Method $Uri failed: $(if ($Status) { "HTTP $Status " })$(if ($Code) { "$Code - " })$Message".Trim()
    $exception = [InvalidOperationException]::new($text)
    $exception.Data['XsmGraph'] = $true
    $exception.Data['Status'] = $Status
    $exception.Data['Code'] = $Code
    $exception.Data['GraphMessage'] = $Message
    return $exception
}

function Get-XsmGraphErrorStatus {
    <# HTTP status of an error thrown by Invoke-XsmGraph (0 when it is not a Graph error). #>
    param([Parameter(Mandatory)]$ErrorRecord)
    $ex = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($ex) {
        if ($ex.Data -and $ex.Data.Contains('XsmGraph')) { return [int]$ex.Data['Status'] }
        $ex = $ex.InnerException
    }
    return 0
}

function Invoke-XsmGraph {
    <#
    .SYNOPSIS
        One Microsoft Graph v1.0 call. Uri is relative to https://graph.microsoft.com/v1.0 (or an absolute
        @odata.nextLink). Returns a hashtable; throws an exception with Data.Status (HTTP status) on error.
    #>
    param([ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    if ($Uri -match '^https://graph\.microsoft\.com/beta') { throw 'The beta endpoint of Microsoft Graph is not used by this tool.' }
    $label = $Uri -replace '^https://graph\.microsoft\.com/v1\.0', ''
    Write-XsmLog 'DEBUG' "Graph $Method $label"
    if ($script:GraphInvoker) { return & $script:GraphInvoker $Method $label $Body }
    $absolute = if ($Uri -match '^https://') { $Uri } else { $script:GraphRoot + $Uri }
    $parameters = @{ Method = $Method; Uri = $absolute; OutputType = 'HashTable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $parameters.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $parameters.ContentType = 'application/json' }
    try {
        return Invoke-MgGraphRequest @parameters
    } catch {
        $status = 0
        try { if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        $text = (@([string]$_.ErrorDetails.Message, [string]$_.Exception.Message) | Where-Object { $_ }) -join "`n"
        if (-not $status -and $text -match 'HTTP/[\d.]+\s+(\d{3})') { $status = [int]$Matches[1] }
        if (-not $status -and $text -match '\b(400|401|403|404|409|429|500|503)\b') { $status = [int]$Matches[1] }
        $code = ''; $message = ($_.Exception.Message -split "`n")[0]
        $json = [regex]::Match($text, '\{\s*"error"\s*:.*\}', 'Singleline')
        if ($json.Success) {
            try { $e = ($json.Value | ConvertFrom-Json -AsHashtable).error; $code = [string]$e.code; if ($e.message) { $message = [string]$e.message } } catch { }
        }
        throw (New-XsmGraphException -Status $status -Code $code -Message $message -Method $Method -Uri $label)
    }
}

function Get-XsmGraphCollection {
    <# Every item of a Graph collection (follows @odata.nextLink). #>
    param([Parameter(Mandatory)][string]$Uri)
    $items = [Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-XsmGraph -Method GET -Uri $next
        foreach ($v in @($page['value'])) { if ($null -ne $v) { $items.Add($v) } }
        $next = [string]$page['@odata.nextLink']
    }
    return $items.ToArray()
}

function Get-XsmGraphOrNull {
    <# GET that returns $null on 404 (object does not exist). #>
    param([Parameter(Mandatory)][string]$Uri)
    try { return Invoke-XsmGraph -Method GET -Uri $Uri }
    catch { if ((Get-XsmGraphErrorStatus $_) -eq 404) { return $null }; throw }
}

function Get-XsmGraphScopes {
    <#
    .SYNOPSIS
        Delegated Microsoft Graph permissions needed by a mode and phase.
    #>
    param([Parameter(Mandatory)][ValidateSet('Collect', 'Plan', 'Apply')][string]$Mode, [ValidateSet('Entra', 'Exchange', 'All')][string]$Phase = 'All', [switch]$Groups)
    $scopes = [Collections.Generic.List[string]]::new()
    $scopes.Add('Policy.Read.All')
    switch ($Mode) {
        'Collect' { $scopes.Add('CrossTenantInformation.ReadBasic.All'); $scopes.Add('Group.Read.All') }
        'Plan' { $scopes.Add('Group.Read.All') }
        'Apply' {
            if ($Phase -in 'Entra', 'All') {
                $scopes.Add('Policy.ReadWrite.CrossTenantAccess')
                if ($Groups) { $scopes.Add('Group.ReadWrite.All') } else { $scopes.Add('Group.Read.All') }
            }
            if ($Phase -in 'Exchange', 'All') {
                $scopes.Add('Policy.ReadWrite.CrossTenantCapability')
                if (-not $scopes.Contains('Group.Read.All') -and -not $scopes.Contains('Group.ReadWrite.All')) { $scopes.Add('Group.Read.All') }
            }
        }
    }
    return , @($scopes | Select-Object -Unique)
}

function Get-XsmExpectedAccount {
    <#
    .SYNOPSIS
        Account expected for a run ('' = any account of the tenant).
    .DESCRIPTION
        -UserPrincipalName first. Then Authentication.EntraAdmin for the Entra phase (Plan -Phase Entra, Apply -Phase
        Entra, Apply -Phase All) - or ExchangeAdmin when EntraAdmin is empty - and Authentication.ExchangeAdmin for
        everything else (Collect, Plan, Apply -Phase Exchange).
    #>
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][ValidateSet('Collect', 'Plan', 'Apply')][string]$Mode,
        [ValidateSet('Entra', 'Exchange', 'All')][string]$Phase = 'All',
        [string]$UserPrincipalName
    )
    if ($UserPrincipalName) { return $UserPrincipalName }
    $entraRun = $Mode -ne 'Collect' -and ($Phase -eq 'Entra' -or ($Mode -eq 'Apply' -and $Phase -eq 'All'))
    if ($entraRun -and $Settings.Authentication.EntraAdmin) { return [string]$Settings.Authentication.EntraAdmin }
    return [string]$Settings.Authentication.ExchangeAdmin
}
