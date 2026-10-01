<#
    X-TAP Sharing Migration - classification.

    Turns the inventory into migration items: one item per feature, per Exchange object and per partner
    tenant. Each item is in scope (an external Microsoft 365 organization) or out of scope, with the
    reason. Pure functions: no connection, fully covered by the tests.

    Reasons (code - meaning - can the administrator force it in Selection.csv?):
      InScope         external Microsoft 365 tenant                                       -
      Hybrid          Exchange hybrid with this organization's own on-premises servers    no  (dedicated Exchange hybrid application)
      SameTenant      a domain of this tenant                                             no
      OnPremises      partner on Exchange Server: the endpoint is not Exchange Online       no  (not part of this migration)
      Disabled        disabled in Exchange Online                                         yes
      Unused          sharing policy assigned to no mailbox                               yes
      TenantNotFound  no Microsoft Entra tenant for the domain                            no
      Consumer        consumer accounts (Outlook.com ...), not an organization            no
      ResolutionError the tenant of the domain could not be resolved (network ...)        no  (collect again)
      NotMigratable   no Microsoft 365 X-TAP equivalent                                   no
      PartnerSide     availability address space: your users read the partner; the X-TAP  yes (if the partner must also
                      equivalent is configured by the partner for your tenant ID               see your users)
#>

$script:Reasons = [ordered]@{
    InScope         = @{ Text = 'External Microsoft 365 tenant'; Overridable = $false }
    Hybrid          = @{ Text = 'Exchange hybrid of this organization - out of scope, handled by the dedicated Exchange hybrid application'; Overridable = $false }
    SameTenant      = @{ Text = 'Domain of this tenant'; Overridable = $false }
    OnPremises      = @{ Text = 'Partner on Exchange Server (endpoint not Exchange Online) - out of scope, not part of this migration'; Overridable = $false }
    Disabled        = @{ Text = 'Disabled in Exchange Online'; Overridable = $true }
    Unused          = @{ Text = 'Sharing policy assigned to no mailbox'; Overridable = $true }
    TenantNotFound  = @{ Text = 'No Microsoft Entra tenant for this domain'; Overridable = $false }
    Consumer        = @{ Text = 'Consumer accounts, not a Microsoft 365 organization'; Overridable = $false }
    ResolutionError = @{ Text = 'Tenant of the domain could not be resolved (run Collect again)'; Overridable = $false }
    NotMigratable   = @{ Text = 'No Microsoft 365 X-TAP equivalent'; Overridable = $false }
    PartnerSide     = @{ Text = 'Configured by the partner: your users read its free/busy (availability address space)'; Overridable = $true }
}

function ConvertFrom-XsmSharingEntry {
    <#
    .SYNOPSIS
        Parses one entry of a sharing policy: 'contoso.com:CalendarSharingFreeBusyDetail, ContactsSharing',
        '*:CalendarSharingFreeBusySimple', 'Anonymous:CalendarSharingFreeBusyReviewer'.
    #>
    param([AllowEmptyString()][string]$Entry)
    $result = [ordered]@{ Raw = $Entry; Kind = 'Invalid'; Domain = ''; Subdomains = $false; Actions = @(); CalendarAction = ''; Level = ''; Other = @() }
    $i = $Entry.IndexOf(':')
    if ($i -lt 1) { return $result }
    $domain = $Entry.Substring(0, $i).Trim()
    $result.Actions = @($Entry.Substring($i + 1).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($domain -ieq 'Anonymous') { $result.Kind = 'Anonymous' }
    elseif ($domain -eq '*') { $result.Kind = 'Wildcard' }
    else {
        $result.Kind = 'Domain'
        if ($domain.StartsWith('*.')) { $result.Subdomains = $true; $domain = $domain.Substring(2) }
        $result.Domain = $domain.ToLowerInvariant()
    }
    $best = -1
    foreach ($action in $result.Actions) {
        $level = $script:ExchangeLevelMap.SharingAction[$action]
        if ($level) {
            $rank = Get-XsmLevelRank 'CalendarSharing' $level
            if ($rank -gt $best) { $best = $rank; $result.CalendarAction = $action; $result.Level = $level }
        }
    }
    $result.Other = @($result.Actions | Where-Object { -not $script:ExchangeLevelMap.SharingAction[$_] })
    return $result
}

function Get-XsmEndpointKind {
    <#
    .SYNOPSIS
        Microsoft365 when one of the endpoints is a Microsoft 365 host, OnPremises when endpoints are set but
        none is, Undetermined when no endpoint is set.
    #>
    param([AllowEmptyCollection()][string[]]$Values = @(), [Parameter(Mandatory)][string[]]$Microsoft365Endpoints)
    $hosts = @(foreach ($v in $Values) {
            if (-not $v) { continue }
            $uri = $null
            if ([Uri]::TryCreate($v, [UriKind]::Absolute, [ref]$uri) -and $uri.Host) { $uri.Host.ToLowerInvariant() } else { $v.Trim().TrimEnd('/').ToLowerInvariant() }
        })
    if (-not $hosts.Count) { return 'Undetermined' }
    foreach ($h in $hosts) {
        foreach ($e in $Microsoft365Endpoints) { if ($h -eq $e -or $h.EndsWith(".$e")) { return 'Microsoft365' } }
    }
    return 'OnPremises'
}

function Group-XsmDomainsByTenant {
    <# Groups domains by the tenant they belong to (one bucket per tenant; not found / errors in their own bucket). #>
    param([string[]]$Domains = @(), [Parameter(Mandatory)]$DomainInfo)
    $buckets = [ordered]@{}
    foreach ($d in $Domains) {
        $info = $DomainInfo[$d]
        if (-not $info) { $info = @{ Domain = $d; Status = 'ResolutionError'; TenantId = ''; DisplayName = ''; Cloud = ''; Error = 'not resolved' } }
        $status = [string]$info.Status
        if ($status -eq 'Error') { $status = 'ResolutionError' }
        $key = if ($status -in 'Resolved', 'Consumer') { [string]$info.TenantId } else { $status }
        if (-not $buckets.Contains($key)) {
            $buckets[$key] = [ordered]@{ TenantId = [string]$info.TenantId; Status = $status; Domains = [Collections.Generic.List[string]]::new(); DisplayName = [string]$info.DisplayName; Cloud = [string]$info.Cloud; Error = [string]$info.Error }
        }
        $buckets[$key].Domains.Add($d)
        if (-not $buckets[$key].DisplayName -and $info.DisplayName) { $buckets[$key].DisplayName = [string]$info.DisplayName }
    }
    return @($buckets.Values | ForEach-Object { $_.Domains = @($_.Domains); $_ })
}

function Get-XsmDiscoveredGroupScope {
    <# Scope value of an organization relationship scope group (FreeBusyAccessScope / MailTipsAccessScope). #>
    param($Group)
    if (-not $Group) { return @{ Token = 'All'; Text = 'All users'; Notes = @() } }
    if (-not $Group.Resolved -or -not $Group.ExternalDirectoryObjectId) {
        return @{ Token = "Unresolved:$($Group.Identity)"; Text = "group $($Group.Identity) (not found)"; Notes = @("The Exchange scope group '$($Group.Identity)' was not found or has no Microsoft Entra object ID: choose a scope in Selection.csv or in the configuration.") }
    }
    $notes = @()
    if (-not $Group.SecurityEnabled) { $notes += "The scope group '$($Group.DisplayName)' is a $($Group.RecipientTypeDetails), not a security group: Microsoft 365 X-TAP needs a security group (choose another scope)." }
    return @{ Token = $Group.ExternalDirectoryObjectId; Text = "group $($Group.DisplayName)"; Notes = $notes }
}

function Get-XsmAssessment {
    <# Reason of an item, in the order of the checks. Hybrid and on-premises come first: never in scope, whatever the rest. #>
    param([bool]$Hybrid, [bool]$Enabled, $Bucket, [string]$EndpointKind = 'Microsoft365', [string]$OwnTenantId, [bool]$Unused, [bool]$NotMigratable)
    if ($Hybrid) { return 'Hybrid' }
    if ($Bucket -and $Bucket.TenantId -and $Bucket.TenantId -eq $OwnTenantId) { return 'SameTenant' }
    if ($EndpointKind -eq 'OnPremises') { return 'OnPremises' }
    if ($NotMigratable) { return 'NotMigratable' }
    if (-not $Enabled) { return 'Disabled' }
    if ($Bucket) {
        switch ($Bucket.Status) {
            'NotFound' { return 'TenantNotFound' }
            'Consumer' { return 'Consumer' }
            'ResolutionError' { return 'ResolutionError' }
        }
    }
    if ($Unused) { return 'Unused' }
    return 'InScope'
}

function New-XsmItem {
    param([Parameter(Mandatory)][hashtable]$Values)
    $reason = $Values.Reason
    $item = [ordered]@{
        ItemId = ''; Source = ''; SourceName = ''; Feature = ''; Target = 'Partner'
        PartnerTenantId = ''; PartnerName = ''; PartnerDomains = @(); PartnerCloud = ''
        ExchangeSetting = ''; DiscoveredLevel = ''; DiscoveredScope = 'All'; DiscoveredScopeText = 'All users'
        Status = $(if ($reason -eq 'InScope') { 'InScope' } else { 'OutOfScope' }); Reason = $reason
        ReasonText = $script:Reasons[$reason].Text; Overridable = $script:Reasons[$reason].Overridable
        Notes = @(); XtapStatus = 'Unknown'; XtapDetail = ''
    }
    foreach ($k in $Values.Keys) { if ($k -ne 'Reason') { $item[$k] = $Values[$k] } }
    $item.Notes = @($item.Notes | Where-Object { $_ })
    return $item
}

function Get-XsmMigrationItems {
    <#
    .SYNOPSIS
        Classifies the inventory of a snapshot. Returns @{ Items; Sources } where Sources gives one
        assessment per Exchange object (also for the objects that produce no item).
    #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Settings)
    $exchange = $Snapshot.Exchange
    $domainInfo = $Snapshot.Domains
    $ownTenant = [string]$Snapshot.Tenant.TenantId
    $ownCloud = [string]$Snapshot.Tenant.Cloud
    $accepted = @($exchange.AcceptedDomains | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $endpoints = $Settings.Collection.Microsoft365Endpoints
    $hybridRelationships = @($exchange.OnPremisesOrganizations | ForEach-Object { [string]$_.OrganizationRelationship } | Where-Object { $_ })
    $items = [Collections.Generic.List[object]]::new()
    $sources = [Collections.Generic.List[object]]::new()
    $partnerLabel = { param($bucket) $first = if (@($bucket.Domains).Count) { @($bucket.Domains)[0] } else { '' }; if ($bucket.DisplayName -and $first) { "$($bucket.DisplayName) ($first)" } elseif ($bucket.DisplayName) { $bucket.DisplayName } elseif ($first) { $first } else { $bucket.TenantId } }
    $onPremNote = { param($values) "Partner endpoint on Exchange Server: $(@($values | Where-Object { $_ } | ForEach-Object { $u = $null; if ([Uri]::TryCreate($_, [UriKind]::Absolute, [ref]$u) -and $u.Host) { $u.Host } else { $_ } } | Select-Object -Unique) -join ', '). Out of scope, cannot be forced: sharing with an on-premises organization is not part of this migration." }
    $hybridNote = 'Exchange hybrid of this organization: out of scope, cannot be forced. It moves with the dedicated Exchange hybrid application.'
    $cloudNote = { param($bucket) if ($ownCloud -and $bucket.Cloud -and $bucket.Cloud -ne $ownCloud) { "Partner in another Microsoft cloud ($($bucket.Cloud)): Microsoft cloud settings must allow it in Microsoft Entra (not configured by this tool)." } }

    # Organization relationships ---------------------------------------------------------------------
    $n = 0
    foreach ($o in @($exchange.OrganizationRelationships)) {
        $n++
        $domains = @($o.DomainNames)
        $hybrid = ($o.Name -match $Settings.Collection.HybridRelationshipNamePattern) -or ($o.Name -in $hybridRelationships) -or [bool](@($domains | Where-Object { $_ -in $accepted }).Count)
        $endpointKind = Get-XsmEndpointKind @($o.TargetApplicationUri, $o.TargetSharingEpr, $o.TargetAutodiscoverEpr) $endpoints
        $features = @()
        if ($o.FreeBusyAccessEnabled -and $script:ExchangeLevelMap.FreeBusyAccessLevel[[string]$o.FreeBusyAccessLevel]) {
            $features += @{ Code = 'FB'; Feature = 'FreeBusy'; Level = $script:ExchangeLevelMap.FreeBusyAccessLevel[[string]$o.FreeBusyAccessLevel]; Setting = "FreeBusyAccessLevel = $($o.FreeBusyAccessLevel)"; Group = $o.FreeBusyScopeGroup; ScopeName = $o.FreeBusyAccessScope }
        }
        if ($o.MailTipsAccessEnabled -and $script:ExchangeLevelMap.MailTipsAccessLevel[[string]$o.MailTipsAccessLevel]) {
            $features += @{ Code = 'MT'; Feature = 'MailTips'; Level = $script:ExchangeLevelMap.MailTipsAccessLevel[[string]$o.MailTipsAccessLevel]; Setting = "MailTipsAccessLevel = $($o.MailTipsAccessLevel)"; Group = $o.MailTipsScopeGroup; ScopeName = $o.MailTipsAccessScope }
        }
        $buckets = @(Group-XsmDomainsByTenant $domains $domainInfo)
        $sourceReasons = [Collections.Generic.List[string]]::new()
        $otherUses = @(foreach ($p in 'MailboxMoveEnabled', 'ArchiveAccessEnabled', 'DeliveryReportEnabled', 'PhotosEnabled') { if ($o[$p]) { $p -replace 'Enabled$', '' } })
        foreach ($f in $features) {
            $k = 0
            foreach ($bucket in $buckets) {
                $k++
                $reason = Get-XsmAssessment -Hybrid $hybrid -Enabled ([bool]$o.Enabled) -Bucket $bucket -EndpointKind $endpointKind -OwnTenantId $ownTenant
                $scope = Get-XsmDiscoveredGroupScope $f.Group
                $notes = @($scope.Notes)
                if ($reason -eq 'InScope' -and $endpointKind -eq 'Undetermined') { $notes += 'No partner endpoint is set on the relationship; the partner tenant was found in Microsoft Entra.' }
                if ($reason -eq 'OnPremises') { $notes += & $onPremNote @($o.TargetApplicationUri, $o.TargetSharingEpr, $o.TargetAutodiscoverEpr) }
                if ($reason -eq 'Hybrid') { $notes += $hybridNote }
                if ($otherUses.Count) { $notes += "The relationship is also used for: $($otherUses -join ', ') (not migrated by this tool; keep the relationship for these uses)." }
                $notes += & $cloudNote $bucket
                $items.Add((New-XsmItem @{
                            ItemId = ('OR{0:00}-{1}{2}' -f $n, $f.Code, $(if ($buckets.Count -gt 1) { "-$k" } else { '' }))
                            Source = 'OrganizationRelationship'; SourceName = $o.Name; Feature = $f.Feature; Target = 'Partner'
                            PartnerTenantId = $bucket.TenantId; PartnerName = (& $partnerLabel $bucket); PartnerDomains = @($bucket.Domains); PartnerCloud = $bucket.Cloud
                            ExchangeSetting = $f.Setting + $(if ($f.ScopeName) { "; scope $($f.ScopeName)" } else { '' })
                            DiscoveredLevel = $f.Level; DiscoveredScope = $scope.Token; DiscoveredScopeText = $scope.Text
                            Reason = $reason; Notes = $notes
                        }))
                $sourceReasons.Add($reason)
            }
        }
        $status = if (-not $features.Count) { 'NoSharing' } elseif ($sourceReasons -contains 'InScope') { 'InScope' } else { @($sourceReasons | Select-Object -Unique) -join ', ' }
        $sources.Add([ordered]@{ Source = 'OrganizationRelationship'; Name = $o.Name; Status = $status; EndpointKind = $endpointKind; Hybrid = $hybrid })
    }

    # Availability address spaces --------------------------------------------------------------------
    $n = 0
    foreach ($a in @($exchange.AvailabilityAddressSpaces)) {
        $n++
        $forest = [string]$a.ForestName
        $hybrid = ($forest -in $accepted) -or ($a.AccessMethod -eq 'InternalProxy')
        $bucket = if ($a.TargetTenantId) {
            $info = if ($forest) { $domainInfo[$forest] } else { $null }
            [ordered]@{ TenantId = [string]$a.TargetTenantId; Status = 'Resolved'; Domains = @($forest | Where-Object { $_ }); DisplayName = $(if ($info -and $info.TenantId -eq $a.TargetTenantId) { [string]$info.DisplayName } else { '' }); Cloud = $(if ($info) { [string]$info.Cloud } else { '' }); Error = '' }
        } else { @(Group-XsmDomainsByTenant @($forest) $domainInfo)[0] }
        $endpointKind = Get-XsmEndpointKind @($a.TargetServiceEpr, $a.TargetAutodiscoverEpr) $endpoints
        $notMigratable = $a.AccessMethod -ne 'OrgWideFBToken'
        $reason = Get-XsmAssessment -Hybrid $hybrid -Enabled $true -Bucket $bucket -EndpointKind $endpointKind -OwnTenantId $ownTenant -NotMigratable $notMigratable
        # An availability address space lets YOUR users read the partner's free/busy. Its X-TAP equivalent is an
        # inbound capability in the PARTNER's tenant, for your tenant ID - not a capability in this tenant.
        if ($reason -eq 'InScope') { $reason = 'PartnerSide' }
        $notes = @(
            'Your users read the free/busy of this partner. The X-TAP equivalent is configured by the partner: crossTenantCalendarAvailabilityBasic in its partner policy for your tenant ID (see the coordination list).'
            'Force Include = Yes in Selection.csv only if the partner must also see the free/busy of your users.'
            'Availability address spaces do not use EWS. The cutover removes the address space (it cannot be disabled), once the partner has configured its side.'
        )
        if ($reason -eq 'NotMigratable') { $notes = @("AccessMethod $($a.AccessMethod): only OrgWideFBToken can be migrated to Microsoft 365 X-TAP.") }
        if ($reason -eq 'OnPremises') { $notes = @(& $onPremNote @($a.TargetServiceEpr, $a.TargetAutodiscoverEpr)) }
        if ($reason -eq 'Hybrid') { $notes = @($hybridNote) }
        $notes += & $cloudNote $bucket
        $items.Add((New-XsmItem @{
                    ItemId = ('AS{0:00}-FB' -f $n); Source = 'AvailabilityAddressSpace'; SourceName = $forest; Feature = 'FreeBusy'; Target = 'Partner'
                    PartnerTenantId = $bucket.TenantId; PartnerName = (& $partnerLabel $bucket); PartnerDomains = @($bucket.Domains); PartnerCloud = $bucket.Cloud
                    ExchangeSetting = "AccessMethod = $($a.AccessMethod)"; DiscoveredLevel = 'Basic'; Reason = $reason; Notes = $notes
                }))
        $sources.Add([ordered]@{ Source = 'AvailabilityAddressSpace'; Name = $forest; Status = $reason; EndpointKind = $endpointKind; Hybrid = $hybrid })
    }

    # Sharing policies --------------------------------------------------------------------------------
    $collected = [bool]$exchange.MailboxAssignmentsCollected
    $used = @($exchange.SharingPolicies | Where-Object { $_.Enabled -and $collected -and [int]$_.Mailboxes -gt 0 })
    $several = $used.Count -gt 1
    $n = 0
    foreach ($p in @($exchange.SharingPolicies)) {
        $n++
        $m = 0
        $policyReasons = [Collections.Generic.List[string]]::new()
        $unused = $collected -and [int]$p.Mailboxes -eq 0 -and -not $p.Default
        foreach ($entry in @($p.Domains)) {
            $m++
            $parsed = ConvertFrom-XsmSharingEntry $entry
            if ($parsed.Kind -eq 'Invalid') { continue }
            $feature = if ($parsed.Kind -eq 'Anonymous') { 'AnonymousCalendarSharing' } else { 'CalendarSharing' }
            $target = if ($parsed.Kind -eq 'Domain') { 'Partner' } else { 'Default' }
            $bucket = if ($parsed.Kind -eq 'Domain') { @(Group-XsmDomainsByTenant @($parsed.Domain) $domainInfo)[0] } else { $null }
            $own = $parsed.Kind -eq 'Domain' -and $parsed.Domain -in $accepted
            $reason = Get-XsmAssessment -Hybrid $false -Enabled ([bool]$p.Enabled) -Bucket $bucket -OwnTenantId $ownTenant -Unused $unused -NotMigratable (-not $parsed.Level)
            if ($own) { $reason = 'SameTenant' }
            $notes = @()
            if ($parsed.Other.Count) { $notes += "$($parsed.Other -join ', ') is not migrated (no Microsoft 365 X-TAP equivalent)." }
            if ($parsed.Subdomains) { $notes += "The entry covers the subdomains of $($parsed.Domain); X-TAP works per tenant (every domain of the tenant)." }
            $scopeToken = 'All'; $scopeText = 'All users'
            if ($several) {
                $scopeToken = "SharingPolicy:$($p.Name)"
                $scopeText = "mailboxes of the sharing policy $($p.Name) ($([int]$p.Mailboxes))"
                $notes += "$($used.Count) sharing policies are in use: the scope is a security group of the $([int]$p.Mailboxes) mailbox(es) of this policy (new mailboxes are not added automatically; use All or a dynamic group if preferred)."
            } elseif (-not $collected) {
                $notes += 'Mailboxes per sharing policy not collected: scope All assumed.'
            }
            if ($p.Default -and $collected -and [int]$p.Mailboxes -eq 0) { $notes += 'Default sharing policy: no mailbox today, but it applies to new mailboxes.' }
            if ($bucket) { $notes += & $cloudNote $bucket }
            $items.Add((New-XsmItem @{
                        ItemId = ('SP{0:00}-{1:00}' -f $n, $m); Source = 'SharingPolicy'; SourceName = $p.Name; Feature = $feature; Target = $target
                        PartnerTenantId = $(if ($bucket) { $bucket.TenantId } else { '' })
                        PartnerName = $(if ($bucket) { & $partnerLabel $bucket } elseif ($target -eq 'Default') { $(if ($parsed.Kind -eq 'Anonymous') { 'Anonymous (internet)' } else { 'All external organizations' }) } else { '' })
                        PartnerDomains = $(if ($bucket) { @($bucket.Domains) } else { @() }); PartnerCloud = $(if ($bucket) { $bucket.Cloud } else { '' })
                        ExchangeSetting = $entry; DiscoveredLevel = $parsed.Level; DiscoveredScope = $scopeToken; DiscoveredScopeText = $scopeText
                        Reason = $reason; Notes = $notes
                    }))
            $policyReasons.Add($reason)
        }
        $status = if (-not $policyReasons.Count) { 'NoSharing' } elseif ($policyReasons -contains 'InScope') { 'InScope' } else { @($policyReasons | Select-Object -Unique) -join ', ' }
        $sources.Add([ordered]@{ Source = 'SharingPolicy'; Name = $p.Name; Status = $status; EndpointKind = ''; Hybrid = $false })
    }

    foreach ($item in $items) { Set-XsmItemXtapStatus -Item $item -Xtap $Snapshot.Xtap }
    return [pscustomobject]@{ Items = $items.ToArray(); Sources = $sources.ToArray() }
}

function Get-XsmPolicyCapabilities {
    <# Capabilities of the default policy or of a partner policy in an X-TAP state; $null when unknown. #>
    param($Xtap, [string]$Target, [string]$TenantId)
    if (-not $Xtap -or -not $Xtap.Readable) { return $null }
    if ($Target -eq 'Default') { return , @($Xtap.Default.Capabilities) }
    $partner = @($Xtap.Partners | Where-Object { $_.TenantId -eq $TenantId }) | Select-Object -First 1
    if (-not $partner) { return , @() }
    return , @($partner.Capabilities)
}

function Test-XsmScopeMatch {
    <# True when a capability includes exactly the resources of a scope value (All or object IDs). #>
    param([AllowEmptyCollection()][object[]]$Included = @(), [AllowEmptyCollection()][string[]]$Wanted = @())
    $have = @($Included | ForEach-Object { if ($_.ResourceId -ieq 'All') { 'all' } else { ([string]$_.ResourceId).ToLowerInvariant() } } | Sort-Object -Unique)
    $want = @($Wanted | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    return (($have -join ',') -eq ($want -join ','))
}

function Set-XsmItemXtapStatus {
    <# Compares an item with the Microsoft 365 X-TAP state read at collection: Present, PresentOtherScope, OtherLevel, Missing, Unknown. #>
    param([Parameter(Mandatory)]$Item, $Xtap)
    if (-not $Item.DiscoveredLevel -or ($Item.Target -eq 'Partner' -and -not $Item.PartnerTenantId) -or $Item.Reason -in 'Hybrid', 'SameTenant', 'TenantNotFound', 'Consumer', 'NotMigratable', 'PartnerSide') { $Item.XtapStatus = 'NotApplicable'; return }
    $caps = Get-XsmPolicyCapabilities $Xtap $Item.Target $Item.PartnerTenantId
    if ($null -eq $caps) { $Item.XtapStatus = 'Unknown'; $Item.XtapDetail = 'Microsoft 365 X-TAP not read'; return }
    $name = Get-XsmCapabilityName $Item.Feature $Item.DiscoveredLevel
    $cap = @($caps | Where-Object { $_.Name -ieq $name -and $_.IsAllowed }) | Select-Object -First 1
    if ($cap) {
        $wanted = if ($Item.DiscoveredScope -ieq 'All') { @('All') } elseif ($Item.DiscoveredScope -match $script:GuidPattern) { @($Item.DiscoveredScope) } else { $null }
        if ($null -ne $wanted -and (Test-XsmScopeMatch $cap.Included $wanted)) { $Item.XtapStatus = 'Present'; $Item.XtapDetail = "$name already allowed with the same scope" }
        else { $Item.XtapStatus = 'PresentOtherScope'; $Item.XtapDetail = "$name already allowed, scope: $(@($cap.Included | ForEach-Object { if ($_.ResourceId -ieq 'All') { 'All' } else { "$($_.ResourceType) $($_.ResourceId)" } }) -join ', ')" }
        return
    }
    $other = @($caps | Where-Object { $_.Feature -eq $Item.Feature -and $_.IsAllowed })
    if ($other.Count) { $Item.XtapStatus = 'OtherLevel'; $Item.XtapDetail = "Other level already allowed: $(@($other.Name) -join ', ')"; return }
    $Item.XtapStatus = 'Missing'; $Item.XtapDetail = ''
}
