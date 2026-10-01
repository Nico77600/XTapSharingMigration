<#
    X-TAP Sharing Migration - in-memory Microsoft Graph for the tests.

    Answers the Microsoft Graph v1.0 calls used by the tool (cross-tenant access policy default and partners,
    m365Capabilities, groups and members) from hashtables, and records every call. FailOn (regular
    expression on "METHOD /uri") makes the matching calls fail with HTTP 403.
#>

function New-FakeCapability {
    param([string]$Name, [bool]$Allowed, [object[]]$Included, [object[]]$Excluded = @())
    @{ '@odata.type' = "#microsoft.graph.$Name"; name = $Name; lastModifiedDateTime = '2026-09-01T00:00:00Z'; inboundAccess = @{ isAllowed = $Allowed; resourceScopes = @{ included = @($Included); excluded = @($Excluded) } } }
}

function New-FakeTenant {
    <# The tenant of TestData.ps1 as Microsoft Graph sees it: same X-TAP state as the snapshot. #>
    $t = @{
        Default  = @{ m365CollaborationInbound = $null; Caps = [ordered]@{} }
        Partners = @{}
        Groups   = @{}
        Calls    = [Collections.Generic.List[string]]::new()
        FailOn   = ''
    }
    $t.Default.Caps['anonymousCalendarSharingFreeBusyReviewer'] = New-FakeCapability 'anonymousCalendarSharingFreeBusyReviewer' $true @(@{ resourceId = 'All'; resourceType = 'user' })
    $t.Partners[$TestTenant.Fabrikam] = @{ m365CollaborationInbound = @{ users = @{ accessType = 'allowed'; targets = @(@{ target = 'AllUsers'; targetType = 'user' }) } }; Caps = [ordered]@{} }
    $t.Partners[$TestTenant.Fabrikam].Caps['crossTenantCalendarAvailabilityBasic'] = New-FakeCapability 'crossTenantCalendarAvailabilityBasic' $true @(@{ resourceId = 'All'; resourceType = 'user' })
    $t.Partners[$TestTenant.Fabrikam].Caps['crossTenantMailTipsLimited'] = New-FakeCapability 'crossTenantMailTipsLimited' $true @(@{ resourceId = 'All'; resourceType = 'user' })
    $t.Groups[$TestTenant.FbScopeGroup] = @{ id = $TestTenant.FbScopeGroup; displayName = 'FB-Scope'; securityEnabled = $true; mailEnabled = $true; groupTypes = @(); membershipRule = $null; members = [Collections.Generic.List[string]]::new() }
    return $t
}

function New-FakeGraphError {
    param([int]$Status, [string]$Code, [string]$Message)
    $e = [InvalidOperationException]::new("Microsoft Graph (fake): HTTP $Status $Code - $Message")
    $e.Data['XsmGraph'] = $true; $e.Data['Status'] = $Status; $e.Data['Code'] = $Code; $e.Data['GraphMessage'] = $Message
    return $e
}

function Invoke-FakeGraph {
    param($T, [string]$Method, [string]$Uri, $Body)
    $T.Calls.Add("$Method $Uri")
    if ($T.FailOn -and "$Method $Uri" -match $T.FailOn) { throw (New-FakeGraphError 403 'Authorization_RequestDenied' 'Insufficient privileges to complete the operation.') }
    $path, $query = $Uri.Split('?', 2)
    # Serialized and read back, as the real call does.
    $b = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable } else { $null }
    $base = '/policies/crossTenantAccessPolicy'
    $partner = { param($tid) $p = $T.Partners[$tid]; if (-not $p) { throw (New-FakeGraphError 404 'Request_ResourceNotFound' "Partner $tid not found") }; $p }
    $checkScopes = {
        param($cap)
        foreach ($s in @($cap.inboundAccess.resourceScopes.included)) {
            if ($s.resourceType -eq 'group' -and -not $T.Groups.ContainsKey($s.resourceId)) { throw (New-FakeGraphError 400 'Request_BadRequest' "Group $($s.resourceId) not found") }
        }
    }
    $newCap = {
        param($body)
        $name = ([string]$body['@odata.type']) -replace '^#microsoft\.graph\.', ''
        & $checkScopes $body
        @{ '@odata.type' = $body['@odata.type']; name = $name; lastModifiedDateTime = [DateTime]::UtcNow.ToString('o'); inboundAccess = $body.inboundAccess }
    }
    switch -Regex ("$Method $path") {
        "^GET $base/default$" { return @{ m365CollaborationInbound = $T.Default.m365CollaborationInbound } }
        "^GET $base/default/m365Capabilities$" { return @{ value = @($T.Default.Caps.Values) } }
        "^POST $base/default/m365Capabilities$" {
            $c = & $newCap $b
            if ($T.Default.Caps.Contains($c.name)) { throw (New-FakeGraphError 409 'Conflict' 'Capability exists') }
            $T.Default.Caps[$c.name] = $c; return $c
        }
        "^PATCH $base/default/m365Capabilities/([^/]+)$" {
            $n = $Matches[1]
            if (-not $T.Default.Caps.Contains($n)) { throw (New-FakeGraphError 404 'NotFound' "Capability $n") }
            & $checkScopes $b
            $T.Default.Caps[$n].inboundAccess = $b.inboundAccess; return $null
        }
        "^GET $base/partners$" { return @{ value = @($T.Partners.Keys | ForEach-Object { @{ tenantId = $_; m365CollaborationInbound = $T.Partners[$_].m365CollaborationInbound } }) } }
        "^POST $base/partners$" {
            $tid = [string]$b.tenantId
            if ($T.Partners.ContainsKey($tid)) { throw (New-FakeGraphError 409 'Conflict' 'Partner exists') }
            $T.Partners[$tid] = @{ m365CollaborationInbound = $b.m365CollaborationInbound; Caps = [ordered]@{} }
            return @{ tenantId = $tid }
        }
        "^GET $base/partners/([0-9a-f-]+)$" { $p = & $partner $Matches[1]; return @{ tenantId = $Matches[1]; m365CollaborationInbound = $p.m365CollaborationInbound } }
        "^PATCH $base/partners/([0-9a-f-]+)$" { $p = & $partner $Matches[1]; if ($b.ContainsKey('m365CollaborationInbound')) { $p.m365CollaborationInbound = $b.m365CollaborationInbound }; return $null }
        "^GET $base/partners/([0-9a-f-]+)/m365Capabilities$" { $p = & $partner $Matches[1]; return @{ value = @($p.Caps.Values) } }
        "^POST $base/partners/([0-9a-f-]+)/m365Capabilities$" {
            $p = & $partner $Matches[1]
            if (-not $p.m365CollaborationInbound -or $p.m365CollaborationInbound.users.accessType -ne 'allowed') { throw (New-FakeGraphError 400 'Request_BadRequest' 'Microsoft 365 collaboration trust required') }
            $c = & $newCap $b
            if ($p.Caps.Contains($c.name)) { throw (New-FakeGraphError 409 'Conflict' 'Capability exists') }
            $p.Caps[$c.name] = $c; return $c
        }
        "^PATCH $base/partners/([0-9a-f-]+)/m365Capabilities/([^/]+)$" {
            $p = & $partner $Matches[1]; $n = $Matches[2]
            if (-not $p.Caps.Contains($n)) { throw (New-FakeGraphError 404 'NotFound' "Capability $n") }
            & $checkScopes $b
            $p.Caps[$n].inboundAccess = $b.inboundAccess; return $null
        }
        '^GET /groups/([0-9a-f-]+)$' {
            $g = $T.Groups[$Matches[1]]
            if (-not $g) { throw (New-FakeGraphError 404 'Request_ResourceNotFound' 'Group not found') }
            return @{ id = $g.id; displayName = $g.displayName; securityEnabled = $g.securityEnabled; mailEnabled = $g.mailEnabled; groupTypes = @($g.groupTypes); membershipRule = $g.membershipRule }
        }
        '^GET /groups$' {
            $raw = (($query -split '&') | Where-Object { $_ -like '$filter=*' }) -replace '^\$filter=', ''
            $filter = [Uri]::UnescapeDataString([string]$raw)
            $name = if ($filter -match "^displayName eq '(.*)'$") { $Matches[1].Replace("''", "'") } else { throw "Fake Graph: filter not supported: $filter" }
            return @{ value = @($T.Groups.Values | Where-Object { $_.displayName -eq $name } | ForEach-Object { @{ id = $_.id; displayName = $_.displayName; securityEnabled = $_.securityEnabled; mailEnabled = $_.mailEnabled; groupTypes = @($_.groupTypes); membershipRule = $_.membershipRule } }) }
        }
        '^POST /groups$' {
            $id = [guid]::NewGuid().ToString()
            $g = @{ id = $id; displayName = $b.displayName; securityEnabled = [bool]$b.securityEnabled; mailEnabled = [bool]$b.mailEnabled; groupTypes = @($b.groupTypes); membershipRule = $b.membershipRule; members = [Collections.Generic.List[string]]::new() }
            $T.Groups[$id] = $g
            return @{ id = $id; displayName = $g.displayName }
        }
        '^PATCH /groups/([0-9a-f-]+)$' {
            $g = $T.Groups[$Matches[1]]
            if (-not $g) { throw (New-FakeGraphError 404 'Request_ResourceNotFound' 'Group not found') }
            $ids = @($b['members@odata.bind'] | ForEach-Object { ($_ -split '/')[-1] })
            if (@($ids | Where-Object { $g.members.Contains($_) }).Count) { throw (New-FakeGraphError 400 'Request_BadRequest' 'One or more added object references already exist for the following modified properties: members.') }
            foreach ($id in $ids) { $g.members.Add($id) }
            return $null
        }
        '^GET /groups/([0-9a-f-]+)/members$' {
            $g = $T.Groups[$Matches[1]]
            return @{ value = @($g.members | ForEach-Object { @{ id = $_ } }) }
        }
        '^POST /groups/([0-9a-f-]+)/members/\$ref$' {
            $g = $T.Groups[$Matches[1]]
            $id = ([string]$b['@odata.id'] -split '/')[-1]
            if ($g.members.Contains($id)) { throw (New-FakeGraphError 400 'Request_BadRequest' 'One or more added object references already exist') }
            $g.members.Add($id); return $null
        }
        default { throw "Fake Graph: no handler for $Method $Uri" }
    }
}

function Set-FakeGraph {
    <# Replaces Microsoft Graph by the in-memory tenant inside the module. #>
    param([Parameter(Mandatory)]$Tenant)
    $handler = ${function:Invoke-FakeGraph}
    $invoker = { param($Method, $Uri, $Body) & $handler $Tenant $Method $Uri $Body }.GetNewClosure()
    InModuleScope XTapSharingMigration -Parameters @{ Invoker = $invoker } {
        param($Invoker)
        $script:GraphInvoker = $Invoker
        $script:RetryDelaySeconds = 0
    }
}
