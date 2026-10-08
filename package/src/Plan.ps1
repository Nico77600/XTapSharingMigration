<#
    X-TAP Sharing Migration - plan.

    1. New-XsmTargetState : decisions per item -> target configuration
                            (security groups, Microsoft 365 collaboration trusts, capabilities).
                            Items for the same policy and capability are merged; their scopes are added.
    2. Get-XsmLiveState   : reads the tenant (Microsoft Graph v1.0) for what the target needs.
    3. New-XsmActions     : compares and lists the actions, by phase:
                              Entra    - security groups, Microsoft 365 collaboration trust per partner
                              Exchange - capabilities in the partner policies and in the default policy
       Operation: Create | Update | AddMembers | Disable | NoChange | Blocked | Conflict
       Status   : ToDo | NoChange | Blocked | Conflict | OtherPhase  (then Done | Failed | Skipped after Apply)
#>

function Get-XsmPolicyPath {
    param([Parameter(Mandatory)][string]$Target, [string]$TenantId)
    if ($Target -eq 'Default') { return '/policies/crossTenantAccessPolicy/default/m365Capabilities' }
    return "/policies/crossTenantAccessPolicy/partners/$TenantId/m365Capabilities"
}

function Get-XsmGroupRequirementKey {
    param([Parameter(Mandatory)]$Spec)
    switch ($Spec.Kind) {
        'Id' { return "id:$($Spec.Id)" }
        'Config' { return "config:$($Spec.Key.ToLowerInvariant())" }
        'Name' { return "name:$($Spec.DisplayName.ToLowerInvariant())" }
        'SharingPolicy' { return "policy:$($Spec.Policy.ToLowerInvariant())" }
    }
    return $null
}

function Get-XsmMailNickname {
    <# mailNickname of a new security group, from its display name (letters, digits, dash; 64 characters at most). #>
    param([Parameter(Mandatory)][string]$DisplayName)
    $nick = ($DisplayName.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
    if (-not $nick) { $nick = 'xtap-group' }
    if ($nick.Length -gt 64) { $nick = $nick.Substring(0, 64).Trim('-') }
    return $nick
}

function Get-XsmLevelConflicts {
    <#
    .SYNOPSIS
        Same partner (or default policy) and same feature, several levels found in Exchange Online for scopes that
        overlap (All, or the same group): the administrator must choose one level. Different levels for different
        groups (several sharing policies) are not a conflict.
    .PARAMETER Entries
        Decision entries (Item, Decision) of the items migrated.
    .OUTPUTS
        One conflict per partner and feature: Key, Target, PartnerTenantId, PartnerName, Feature, Options (Level,
        ItemIds, Sources, Domains, Scopes), ItemIds.
    #>
    param([AllowEmptyCollection()][object[]]$Entries = @(), [Parameter(Mandatory)]$Settings)
    $conflicts = [Collections.Generic.List[object]]::new()
    # Only the levels that come from Exchange Online: a level chosen in Selection.csv or the configuration is a decision.
    $candidates = @($Entries | Where-Object { $_.Decision.Include -and -not @($_.Decision.Problems).Count -and $_.Decision.LevelOrigin -eq 'Exchange Online' })
    foreach ($set in ($candidates | Group-Object { Get-XsmLevelChoiceKey $_.Item })) {
        $levels = @($set.Group | Group-Object { $_.Decision.Level })
        if ($levels.Count -lt 2) { continue }
        $tokens = @{}
        $overlap = $false
        foreach ($lv in $levels) {
            $mine = @($lv.Group | ForEach-Object { ConvertTo-XsmScopeSpec $_.Decision.Scope $Settings } | ForEach-Object { $_.Token.ToLowerInvariant() } | Select-Object -Unique)
            if ($mine -contains 'all') { $overlap = $true }
            foreach ($t in $mine) { if ($tokens.ContainsKey($t) -and $tokens[$t] -ne $lv.Name) { $overlap = $true }; $tokens[$t] = $lv.Name }
        }
        if (-not $overlap) { continue }
        $first = $set.Group[0].Item
        $feature = [string]$first.Feature
        $options = @($levels | Sort-Object { Get-XsmLevelRank $feature $_.Name } | ForEach-Object {
                [ordered]@{
                    Level   = $_.Name
                    ItemIds = @($_.Group | ForEach-Object { [string]$_.Item.ItemId })
                    Sources = @($_.Group | ForEach-Object { "$($_.Item.SourceName)" } | Select-Object -Unique)
                    Domains = @($_.Group | ForEach-Object { $_.Item.PartnerDomains } | Where-Object { $_ } | Select-Object -Unique)
                    Scopes  = @($_.Group | ForEach-Object { [string]$_.Item.DiscoveredScopeText } | Select-Object -Unique)
                    Text    = $script:FeatureCatalog[$feature].Text[$_.Name]
                }
            })
        $conflicts.Add([ordered]@{
                Key = $set.Name; Target = $(if ($feature -eq 'AnonymousCalendarSharing') { 'Default' } else { [string]$first.Target })
                PartnerTenantId = [string]$first.PartnerTenantId
                PartnerName = [string]$first.PartnerName
                Feature = $feature; Options = $options; ItemIds = @($set.Group | ForEach-Object { [string]$_.Item.ItemId })
                Chosen = ''
            })
    }
    return $conflicts.ToArray()
}

function Get-XsmLevelChoiceKey {
    <# Key of a level choice: policy (partner tenant ID or default) and feature. #>
    param([Parameter(Mandatory)]$Item)
    $target = if ($Item.Feature -eq 'AnonymousCalendarSharing') { 'Default' } else { [string]$Item.Target }
    $tid = if ($target -eq 'Partner') { ([string]$Item.PartnerTenantId).ToLowerInvariant() } else { '' }
    return "$target|$tid|$($Item.Feature)".ToLowerInvariant()
}

function Import-XsmLevelChoices {
    <# Level choices recorded for a snapshot (LevelChoices.json in the Collect folder): key -> choice. #>
    param([Parameter(Mandatory)]$Snapshot)
    $file = Join-Path $Snapshot.Directory 'LevelChoices.json'
    $choices = @{}
    if (Test-Path -LiteralPath $file) {
        $data = [IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable
        foreach ($c in @($data['Choices'])) { if ($c -and $c['Key'] -and $c['Level']) { $choices[[string]$c['Key']] = $c } }
    }
    return $choices
}

function Save-XsmLevelChoices {
    <# Writes the level choices next to the snapshot, so that the next runs (and the other administrator) reuse them. #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][hashtable]$Choices)
    $data = [ordered]@{
        Info    = 'Levels chosen by the administrator when several levels were found in Exchange Online for the same partner and feature. Delete an entry to be asked again.'
        Choices = @($Choices.Values | Sort-Object { $_['Key'] })
    }
    Save-XsmJson $data (Join-Path $Snapshot.Directory 'LevelChoices.json')
}

function New-XsmTargetState {
    <#
    .SYNOPSIS
        Decisions for every item and the target configuration they produce.
    .PARAMETER Selection
        Result of Import-XsmSelection, or $null to migrate every item proposed (Include = Yes).
    .PARAMETER MailboxesByPolicy
        Mailbox object IDs per sharing policy (Import-XsmSharingPolicyMailboxes), for SharingPolicy groups.
    .PARAMETER LevelChoices
        Levels chosen by the administrator for the level conflicts (Import-XsmLevelChoices): key -> @{ Level }.
        An unresolved conflict blocks its items (they get a problem); the other items go on.
    #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Settings, $Selection, [hashtable]$MailboxesByPolicy = @{}, [hashtable]$LevelChoices = @{})
    $decisions = [Collections.Generic.List[object]]::new()
    $capabilities = [ordered]@{}
    $groups = [ordered]@{}
    $warnings = [Collections.Generic.List[string]]::new()

    # Pass 1 - decision of every item, then the level conflicts and the administrator's choices.
    foreach ($item in @($Snapshot.Items)) {
        $row = if ($Selection) { $Selection.Rows[[string]$item.ItemId] } else { $null }
        $d = Get-XsmItemDecision -Item $item -Settings $Settings -Row $row -UseSelection:([bool]$Selection)
        $decisions.Add([ordered]@{ Item = $item; Decision = $d; CapabilityKey = '' })
    }
    $conflicts = @(Get-XsmLevelConflicts -Entries $decisions.ToArray() -Settings $Settings)
    foreach ($c in $conflicts) {
        $choice = $LevelChoices[$c.Key]
        $level = if ($choice) { Resolve-XsmLevelName $c.Feature ([string]$choice['Level']) } else { $null }
        foreach ($entry in @($decisions | Where-Object { [string]$_.Item.ItemId -in $c.ItemIds })) {
            $d = $entry.Decision
            if ($level) {
                $d.Level = $level
                $d.LevelOrigin = "Administrator choice ($(if ($choice['By']) { $choice['By'] } else { 'LevelChoices.json' }))"
            } else {
                $found = @($c.Options | ForEach-Object { "$($_.Level) ($(@($_.Sources) -join ', '))" }) -join ' / '
                $d.Problems = @($d.Problems) + "Several levels of $($c.Feature) found for $($c.PartnerName): $found. Choose one: answer the question of an interactive Plan or Apply, or set the level in Selection.csv or in a Partners rule."
            }
        }
        if ($level) { $c.Chosen = $level }
    }

    # Pass 2 - target configuration.
    foreach ($entry in $decisions) {
        $item = $entry.Item; $d = $entry.Decision
        if (-not $d.Include -or @($d.Problems).Count) { continue }

        $capName = Get-XsmCapabilityName $item.Feature $d.Level
        $target = if ($item.Feature -eq 'AnonymousCalendarSharing') { 'Default' } else { [string]$item.Target }
        $tid = if ($target -eq 'Partner') { ([string]$item.PartnerTenantId).ToLowerInvariant() } else { '' }
        $key = "$target|$tid|$capName".ToLowerInvariant()
        $entry.CapabilityKey = $key
        if (-not $capabilities.Contains($key)) {
            $capabilities[$key] = [ordered]@{
                Key = $key; Target = $target; PartnerTenantId = $tid
                PartnerName = $(if ($target -eq 'Partner') { [string]$item.PartnerName } else { 'Default policy' })
                PartnerDomains = [Collections.Generic.List[string]]::new(); Feature = $item.Feature; Level = $d.Level; Capability = $capName
                Specs = [Collections.Generic.List[hashtable]]::new(); ItemIds = [Collections.Generic.List[string]]::new()
            }
        }
        $cap = $capabilities[$key]
        $cap.ItemIds.Add($item.ItemId)
        foreach ($dom in @($item.PartnerDomains)) { if ($dom -and -not $cap.PartnerDomains.Contains($dom)) { $cap.PartnerDomains.Add($dom) } }
        foreach ($spec in (ConvertTo-XsmScopeSpec $d.Scope $Settings)) {
            if (-not @($cap.Specs | Where-Object { $_.Token -ieq $spec.Token }).Count) { $cap.Specs.Add($spec) }
        }
    }

    foreach ($cap in $capabilities.Values) {
        # "All" covers every other scope of the same capability.
        if (@($cap.Specs | Where-Object Kind -eq 'All').Count -and $cap.Specs.Count -gt 1) {
            $warnings.Add("$($cap.Capability) for $($cap.PartnerName): the items have different scopes, one of them All users - All users is kept.")
            $all = @($cap.Specs | Where-Object Kind -eq 'All')[0]
            $cap.Specs.Clear(); $cap.Specs.Add($all)
        }
        foreach ($spec in $cap.Specs) {
            $gk = Get-XsmGroupRequirementKey $spec
            if (-not $gk) { continue }
            if (-not $groups.Contains($gk)) {
                $req = [ordered]@{
                    Key = $gk; Kind = $spec.Kind; DisplayName = [string]$spec.DisplayName; Id = [string]$spec.Id; Create = $false
                    MembershipRule = ''; Description = ''; MailNickname = ''; Policy = ''; MemberIds = @(); UsedBy = [Collections.Generic.List[string]]::new()
                }
                switch ($spec.Kind) {
                    'Config' {
                        $g = $Settings.Groups[$spec.Key]
                        $req.Create = [bool]$g.Create; $req.MembershipRule = $g.MembershipRule; $req.Description = $g.Description
                        $req.MailNickname = if ($g.MailNickname) { $g.MailNickname } elseif ($g.DisplayName) { Get-XsmMailNickname $g.DisplayName } else { '' }
                        if (-not $req.Description) { $req.Description = 'Microsoft 365 cross-tenant access policy scope (X-TAP Sharing Migration).' }
                    }
                    'SharingPolicy' {
                        $req.Create = [bool]$spec.Create; $req.Policy = $spec.Policy
                        $req.Description = "Mailboxes of the Exchange Online sharing policy '$($spec.Policy)' - Microsoft 365 X-TAP calendar sharing scope (X-TAP Sharing Migration)."
                        $req.MailNickname = Get-XsmMailNickname $spec.DisplayName
                        $members = $MailboxesByPolicy[$spec.Policy.ToLowerInvariant()]
                        $req.MemberIds = if ($members) { @($members | Sort-Object -Unique) } else { @() }
                    }
                }
                $groups[$gk] = $req
            }
            $groups[$gk].UsedBy.Add($cap.Key)
        }
    }

    # Two levels of the same feature in the same policy: allowed by X-TAP (different scopes), reported.
    foreach ($set in ($capabilities.Values | Group-Object { "$($_.Target)|$($_.PartnerTenantId)|$($_.Feature)" } | Where-Object Count -gt 1)) {
        $names = @($set.Group | ForEach-Object { "$($_.Capability) ($(Format-XsmScope $_.Specs))" })
        $warnings.Add("$($set.Group[0].PartnerName): several levels of $($set.Group[0].Feature) - $($names -join '; '). A user in several scopes gets the most detailed level.")
    }

    $aasTenants = @($Snapshot.Exchange.AvailabilityAddressSpaces | ForEach-Object { [string]$_.TargetTenantId } | Where-Object { $_ })
    $trusts = @($capabilities.Values | Where-Object Target -eq 'Partner' | Group-Object { $_.PartnerTenantId } | ForEach-Object {
            $domains = @($_.Group | ForEach-Object { $_.PartnerDomains } | Select-Object -Unique)
            [ordered]@{
                TenantId = $_.Name; PartnerName = $_.Group[0].PartnerName; Domains = $domains
                Confirmation = Get-XsmPartnerConfirmation -TenantId $_.Name -Domains $domains -Settings $Settings -AddressSpaceTenantIds $aasTenants
            }
        })
    [pscustomobject]@{
        Decisions    = $decisions.ToArray()
        Capabilities = @($capabilities.Values)
        Groups       = @($groups.Values)
        Trusts       = $trusts
        Warnings     = $warnings.ToArray()
        Conflicts    = $conflicts
    }
}

function Request-XsmLevelChoices {
    <#
    .SYNOPSIS
        Asks the administrator to choose a level for each unresolved conflict and records the answers.
        Returns the number of choices made. Enter (or 0) skips a conflict: its items stay blocked for this run.
    #>
    param([Parameter(Mandatory)][object[]]$Conflicts, [Parameter(Mandatory)][hashtable]$Choices, [string]$Account)
    $made = 0
    foreach ($c in @($Conflicts | Where-Object { -not $_.Chosen })) {
        $label = $script:FeatureCatalog[$c.Feature].Label
        Write-XsmSection ("Choice needed  -  {0}  {1}  {2}" -f $c.PartnerName, $script:Dot, $label) -Icon Question
        Write-XsmItem Info ("Exchange Online gives {0} levels for the same users of this {1}. X-TAP needs one:" -f @($c.Options).Count, $(if ($c.Target -eq 'Partner') { 'partner' } else { 'policy' })) -Indent 8
        $i = 0
        foreach ($o in $c.Options) {
            $i++
            Write-Host ("          {0}{1}{2}  {3,-15} {4}" -f $script:C.Bold, $i, $script:C.Reset, $o.Level, $o.Text)
            Write-Host ("             {0}from {1}{2}{3}" -f $script:C.Dim, (@($o.Sources) -join ', '), $(if (@($o.Domains).Count) { "  $($script:Dot) $(@($o.Domains) -join ', ')" }), $script:C.Reset)
        }
        $answer = Read-Host ("          Level for {0} - {1} [1-{2}, Enter = decide later]" -f $c.PartnerName, $label, $i)
        Write-XsmLog 'INFO' "Level choice $($c.Key): answer '$answer'"
        $n = 0
        if ([int]::TryParse("$answer".Trim(), [ref]$n) -and $n -ge 1 -and $n -le $i) {
            $level = $c.Options[$n - 1].Level
            $Choices[$c.Key] = [ordered]@{ Key = $c.Key; Partner = $c.PartnerName; PartnerTenantId = $c.PartnerTenantId; Feature = $c.Feature; Level = $level; Options = @($c.Options | ForEach-Object { $_.Level }); By = $Account; At = [DateTime]::UtcNow.ToString('o') }
            Write-XsmItem Ok "$label $($script:Arrow) $level for $($c.PartnerName) (recorded in LevelChoices.json)" -Indent 8
            $made++
        } else {
            Write-XsmItem Skip "No choice: the items of $($c.PartnerName) - $label stay blocked for this run." -Indent 8
        }
    }
    return $made
}

# ---------------------------------------------------------------------------------------------------
# Live state
# ---------------------------------------------------------------------------------------------------
function Find-XsmGroup {
    <# Reads a group by object ID or display name. Returns Found / Ambiguous / properties. #>
    param([string]$Id, [string]$DisplayName, [switch]$Members)
    $select = 'id,displayName,securityEnabled,mailEnabled,groupTypes,membershipRule'
    $result = [ordered]@{ Found = $false; Ambiguous = $false; Id = ''; DisplayName = $DisplayName; SecurityEnabled = $false; MailEnabled = $false; Dynamic = $false; MembershipRule = ''; MemberIds = $null }
    $group = $null
    if ($Id) { $group = Get-XsmGraphOrNull "/groups/$($Id)?`$select=$select" }
    elseif ($DisplayName) {
        $filter = [Uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
        $found = @(Get-XsmGraphCollection "/groups?`$filter=$filter&`$select=$select")
        if ($found.Count -gt 1) { $result.Ambiguous = $true; return $result }
        if ($found.Count) { $group = $found[0] }
    }
    if (-not $group) { return $result }
    $result.Found = $true
    $result.Id = ([string]$group['id']).ToLowerInvariant()
    $result.DisplayName = [string]$group['displayName']
    $result.SecurityEnabled = [bool]$group['securityEnabled']
    $result.MailEnabled = [bool]$group['mailEnabled']
    $result.Dynamic = @($group['groupTypes']) -contains 'DynamicMembership'
    $result.MembershipRule = [string]$group['membershipRule']
    if ($Members) { $result.MemberIds = @(Get-XsmGraphCollection "/groups/$($result.Id)/members?`$select=id" | ForEach-Object { ([string]$_['id']).ToLowerInvariant() }) }
    return $result
}

function Get-XsmLiveState {
    <#
    .SYNOPSIS
        Reads in the tenant what the target configuration needs: default policy, partner policies of the
        target partners, groups used as scopes (and the members of the sharing policy groups when -Members).
    .PARAMETER KnownGroupIds
        Group key -> object ID of groups created by this execution (read by ID: the display name search
        may not find a group created a few seconds ago).
    #>
    param([Parameter(Mandatory)]$Target, [switch]$Members, [hashtable]$KnownGroupIds = @{})
    $default = Invoke-XsmGraph GET '/policies/crossTenantAccessPolicy/default'
    $live = [ordered]@{
        ReadAt   = [DateTime]::UtcNow.ToString('o')
        Default  = [ordered]@{ Trust = ConvertTo-XsmTrust $default['m365CollaborationInbound']; Capabilities = @(Get-XsmGraphCollection '/policies/crossTenantAccessPolicy/default/m365Capabilities' | ForEach-Object { ConvertTo-XsmCapability $_ }) }
        Partners = [ordered]@{}
        Groups   = [ordered]@{}
    }
    foreach ($tid in @($Target.Trusts | ForEach-Object { $_.TenantId })) { $live.Partners[$tid] = Get-XsmXtapPartner $tid }
    foreach ($tid in @($Target.Capabilities | Where-Object Target -eq 'Partner' | ForEach-Object { $_.PartnerTenantId } | Select-Object -Unique)) {
        if (-not $live.Partners.Contains($tid)) { $live.Partners[$tid] = Get-XsmXtapPartner $tid }
    }
    $live.GroupNames = Resolve-XsmGroupNames (@($live.Default.Capabilities) + @($live.Partners.Values | Where-Object { $_ } | ForEach-Object { $_.Capabilities }))
    foreach ($g in @($Target.Groups)) {
        $id = if ($KnownGroupIds.ContainsKey($g.Key)) { $KnownGroupIds[$g.Key] } else { $g.Id }
        $live.Groups[$g.Key] = Find-XsmGroup -Id $id -DisplayName $g.DisplayName -Members:($Members -and $g.Kind -eq 'SharingPolicy')
    }
    return $live
}

# ---------------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------------
function Format-XsmLiveScope {
    param($Capability, [hashtable]$GroupNames = @{})
    if (-not $Capability) { return '-' }
    $text = @($Capability.Included | ForEach-Object {
            if ($_.ResourceId -ieq 'All') { 'All users' }
            elseif ($GroupNames.ContainsKey(([string]$_.ResourceId).ToLowerInvariant())) { $GroupNames[([string]$_.ResourceId).ToLowerInvariant()] }
            else { "$($_.ResourceType) $($_.ResourceId)" }
        }) -join ' + '
    if (-not $text) { $text = 'nobody' }
    if (@($Capability.Excluded).Count) { $text += " (excluded: $(@($Capability.Excluded | ForEach-Object { $_.ResourceId }) -join ', '))" }
    if (-not $Capability.IsAllowed) { $text = "not allowed $($script:Dot) $text" }
    return $text
}

function New-XsmAction {
    param([Parameter(Mandatory)][hashtable]$Values)
    $a = [ordered]@{
        Id = ''; Key = ''; Phase = ''; Kind = ''; Operation = ''; Status = ''; InPhase = $false
        PartnerTenantId = ''; PartnerName = ''; Feature = ''; Capability = ''; Target = ''
        Before = '-'; After = '-'; Detail = ''; Notes = @(); ItemIds = @(); Error = ''; Verified = ''
        Ref = $null
    }
    foreach ($k in $Values.Keys) { $a[$k] = $Values[$k] }
    return $a
}

function New-XsmActions {
    <#
    .SYNOPSIS
        Compares the target configuration with the tenant and returns the ordered list of actions.
    .PARAMETER Phase
        Entra, Exchange or All: the actions of the other phase are listed with Status OtherPhase.
    #>
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Live, [Parameter(Mandatory)]$Settings, [ValidateSet('Entra', 'Exchange', 'All')][string]$Phase = 'All')
    $actions = [Collections.Generic.List[object]]::new()
    $entraIn = $Phase -in 'Entra', 'All'
    $exchangeIn = $Phase -in 'Exchange', 'All'
    $statusOf = { param([string]$Operation, [bool]$InPhase)
        switch ($Operation) {
            'NoChange' { 'NoChange' } 'Blocked' { 'Blocked' } 'Conflict' { 'Conflict' }
            default { if ($InPhase) { 'ToDo' } else { 'OtherPhase' } }
        } }
    $groupNames = @{}
    if ($Live.GroupNames) { foreach ($k in $Live.GroupNames.Keys) { $groupNames[$k] = $Live.GroupNames[$k] } }
    foreach ($g in $Live.Groups.Values) { if ($g.Found -and $g.Id) { $groupNames[$g.Id] = $g.DisplayName } }

    # Entra - security groups --------------------------------------------------------------------------
    $groupState = @{}
    foreach ($req in @($Target.Groups)) {
        $lg = $Live.Groups[$req.Key]
        $op = 'NoChange'; $detail = ''; $after = $req.DisplayName; $before = '-'; $notes = @()
        $kindText = if ($req.Kind -eq 'SharingPolicy') { "assigned, $($req.MemberIds.Count) mailbox(es) of the sharing policy $($req.Policy)" } elseif ($req.MembershipRule) { "dynamic: $($req.MembershipRule)" } elseif ($req.Create) { 'assigned (members added by you)' } else { 'existing group' }
        if ($lg.Ambiguous) { $op = 'Blocked'; $detail = "Several groups are named '$($req.DisplayName)': use the object ID as scope." }
        elseif ($lg.Found) {
            $before = "$($lg.DisplayName) ($($lg.Id))"
            $after = $before
            if (-not $lg.SecurityEnabled) { $op = 'Blocked'; $detail = "'$($lg.DisplayName)' is not a security group: Microsoft 365 X-TAP needs a security group." }
            elseif ($req.Kind -eq 'SharingPolicy' -and $req.Create -and $null -ne $lg.MemberIds) {
                $missing = @($req.MemberIds | Where-Object { $_ -notin $lg.MemberIds })
                $extra = @($lg.MemberIds | Where-Object { $_ -notin $req.MemberIds }).Count
                if ($missing.Count) { $op = 'AddMembers'; $detail = "$($missing.Count) mailbox(es) of the sharing policy $($req.Policy) to add"; $req['MissingIds'] = $missing }
                if ($extra) { $notes += "$extra member(s) not in the sharing policy at collection time are kept (the tool never removes members)." }
            }
        } else {
            if ($req.Create) { $op = 'Create'; $after = "$($req.DisplayName) - security group, $kindText"; $detail = 'New security group' }
            elseif ($req.Kind -eq 'SharingPolicy') { $op = 'Blocked'; $detail = "Group '$($req.DisplayName)' not found and SharingPolicyGroups.Create = `$false: create it, or choose another scope." }
            else { $op = 'Blocked'; $detail = "Group '$(if ($req.DisplayName) { $req.DisplayName } else { $req.Id })' not found in Microsoft Entra ID." }
        }
        if ($req.Create -and $req.Kind -eq 'SharingPolicy' -and -not $req.MemberIds.Count -and $op -eq 'Create') { $notes += 'No mailbox of this sharing policy in the snapshot: the group is created empty.' }
        $groupState[$req.Key] = @{ Operation = $op; Id = $(if ($lg.Found) { $lg.Id } else { '' }); Name = $(if ($req.DisplayName) { $req.DisplayName } elseif ($lg.Found) { $lg.DisplayName } else { $req.Id }) }
        $actions.Add((New-XsmAction @{
                    Key = "group|$($req.Key)"; Phase = 'Entra'; Kind = 'Group'; Operation = $op; InPhase = $entraIn; Status = (& $statusOf $op $entraIn)
                    Target = $groupState[$req.Key].Name; PartnerName = 'Microsoft Entra ID'; Before = $before; After = $after; Detail = $detail; Notes = $notes
                    Ref = $req
                }))
    }

    # Entra - Microsoft 365 collaboration trust ------------------------------------------------------
    $trustState = @{}
    foreach ($t in @($Target.Trusts)) {
        $lp = $Live.Partners[$t.TenantId]
        $op = 'NoChange'; $detail = ''; $notes = @(); $before = 'no partner policy'
        $after = "Microsoft 365 collaboration allowed $($script:Dot) all users of the partner"
        # Confirmation of the partner tenant ID (the existing partner policy counts once the tenant is read).
        $confirmation = $t.Confirmation
        if (-not $confirmation) { $confirmation = @{ State = 'NotConfirmed'; Source = ''; Detail = '' } }
        if ($confirmation.State -eq 'NotConfirmed' -and $lp) { $confirmation = @{ State = 'Confirmed'; Source = 'existing partner policy in Microsoft Entra'; Detail = '' } }
        $t['ConfirmationState'] = $confirmation.State
        $confirmText = switch ($confirmation.State) { 'Confirmed' { "tenant ID confirmed ($($confirmation.Source))" } 'Mismatch' { 'tenant ID MISMATCH' } default { 'tenant ID not confirmed' } }
        if (-not $lp) { $op = 'Create'; $detail = 'Partner policy created with the Microsoft 365 collaboration trust only (other settings inherit the default policy).' }
        else {
            $before = switch ($lp.Trust.State) {
                'NotConfigured' { 'partner policy without Microsoft 365 collaboration' }
                'AllowedAllUsers' { "Microsoft 365 collaboration allowed $($script:Dot) all users" }
                'AllowedSome' { "Microsoft 365 collaboration allowed $($script:Dot) $(@($lp.Trust.Targets | ForEach-Object { $_.Target }) -join ', ')" }
                'Blocked' { 'Microsoft 365 collaboration blocked' }
            }
            switch ($lp.Trust.State) {
                'NotConfigured' { $op = 'Update'; $detail = 'Microsoft 365 collaboration trust added to the existing partner policy.' }
                'AllowedAllUsers' { $after = $before }
                'AllowedSome' {
                    if ($Settings.Entra.ReplaceRestrictedTrust) { $op = 'Update'; $detail = 'Restricted trust replaced by all users (Entra.ReplaceRestrictedTrust = $true).' }
                    else { $after = $before; $notes += 'The trust is restricted to some users of the partner: only they can use the capabilities. Kept (Entra.ReplaceRestrictedTrust = $false).' }
                }
                'Blocked' {
                    if ($Settings.Entra.ReplaceRestrictedTrust) { $op = 'Update'; $detail = 'Blocked trust replaced by allowed for all users (Entra.ReplaceRestrictedTrust = $true).' }
                    else { $op = 'Conflict'; $detail = 'Microsoft 365 collaboration is blocked for this partner. Not changed (Entra.ReplaceRestrictedTrust = $false): the capabilities cannot work.' }
                }
            }
        }
        if ($confirmation.State -eq 'Mismatch') { $op = 'Blocked'; $detail = $confirmation.Detail }
        elseif ($confirmation.State -eq 'NotConfirmed' -and $Settings.Entra.RequireConfirmedPartners) {
            $op = 'Blocked'
            $detail = "$($confirmation.Detail) Ask the partner's administrator for its tenant ID and add it to Partners: @{ Match = '$(@($t.Domains)[0])'; TenantId = '$($t.TenantId)' } (or set Entra.RequireConfirmedPartners = `$false)."
        }
        $notes = @($notes) + $confirmText
        $trustState[$t.TenantId] = $op
        $actions.Add((New-XsmAction @{
                    Key = "trust|$($t.TenantId)"; Phase = 'Entra'; Kind = 'Trust'; Operation = $op; InPhase = $entraIn; Status = (& $statusOf $op $entraIn)
                    Target = $t.PartnerName; PartnerTenantId = $t.TenantId; PartnerName = $t.PartnerName; Before = $before; After = $after; Detail = $detail; Notes = $notes
                    Ref = $t
                }))
    }

    # Exchange - capabilities ------------------------------------------------------------------------
    $desiredNames = @{}
    foreach ($cap in @($Target.Capabilities)) { $desiredNames["$($cap.Target)|$($cap.PartnerTenantId)|$($cap.Capability)".ToLowerInvariant()] = $true }
    foreach ($cap in @($Target.Capabilities)) {
        $policyCaps = if ($cap.Target -eq 'Default') { @($Live.Default.Capabilities) } elseif ($Live.Partners[$cap.PartnerTenantId]) { @($Live.Partners[$cap.PartnerTenantId].Capabilities) } else { @() }
        $existing = @($policyCaps | Where-Object { $_.Name -ieq $cap.Capability }) | Select-Object -First 1
        $blockers = [Collections.Generic.List[string]]::new()
        $notes = [Collections.Generic.List[string]]::new()
        $pending = $false
        $wantedIds = [Collections.Generic.List[string]]::new()

        if ($cap.Target -eq 'Partner') {
            switch ($trustState[$cap.PartnerTenantId]) {
                'Conflict' { $blockers.Add('Microsoft 365 collaboration is blocked for this partner (Entra).') }
                'Blocked' { $blockers.Add('The partner tenant ID is not confirmed or does not match (see the Entra trust action).') }
                { $_ -in 'Create', 'Update' } { if ($entraIn) { $pending = $true } else { $blockers.Add('Microsoft 365 collaboration trust missing: run -Phase Entra first.') } }
            }
        }
        foreach ($spec in $cap.Specs) {
            if ($spec.Kind -eq 'All') { $wantedIds.Add('All'); continue }
            $gk = Get-XsmGroupRequirementKey $spec
            $gs = $groupState[$gk]
            switch ($gs.Operation) {
                { $_ -in 'NoChange', 'AddMembers' } { $wantedIds.Add($gs.Id) }
                'Create' { if ($entraIn) { $pending = $true; $wantedIds.Add("new:$gk") } else { $blockers.Add("Group '$($gs.Name)' does not exist yet: run -Phase Entra first.") } }
                default { $blockers.Add("Scope group '$($gs.Name)' cannot be used (see the Entra actions).") }
            }
        }
        $op = 'Create'; $detail = "$($script:FeatureCatalog[$cap.Feature].Text[$cap.Level])"
        $extra = @()
        $before = if ($existing) { Format-XsmLiveScope $existing $groupNames } else { '-' }
        if ($blockers.Count) { $op = 'Blocked'; $detail = $blockers -join ' ' }
        elseif ($existing) {
            $mode = $Settings.Apply.ExistingCapability
            $haveIds = @($existing.Included | ForEach-Object { if ($_.ResourceId -ieq 'All') { 'all' } else { ([string]$_.ResourceId).ToLowerInvariant() } })
            $covered = -not $pending -and ($haveIds -contains 'all' -or -not @($wantedIds | Where-Object { $_.ToLowerInvariant() -notin $haveIds }).Count)
            $same = $existing.IsAllowed -and -not @($existing.Excluded).Count -and -not $pending -and (Test-XsmScopeMatch $existing.Included @($wantedIds))
            if ($same -or ($mode -eq 'Merge' -and $existing.IsAllowed -and -not @($existing.Excluded).Count -and $covered)) { $op = 'NoChange'; $detail = 'Already in place.' }
            elseif ($mode -eq 'Replace') { $op = 'Update'; $detail = 'The capability exists with another scope or is not allowed: replaced (Apply.ExistingCapability = Replace).' }
            elseif ($mode -eq 'Merge') {
                $op = 'Update'
                $detail = 'The capability exists with another scope or is not allowed: the target scope is added to the existing one (Apply.ExistingCapability = Merge).'
                $wantedLower = @($wantedIds | ForEach-Object { $_.ToLowerInvariant() })
                $extra = if ($wantedLower -contains 'all') { @() } else { @($existing.Included | Where-Object { $(if ($_.ResourceId -ieq 'All') { 'all' } else { ([string]$_.ResourceId).ToLowerInvariant() }) -notin $wantedLower }) }
            } else {
                $op = 'Conflict'
                $detail = "Already configured in X-TAP with another scope ($before), or not allowed. Kept (Apply.ExistingCapability = Keep): to keep this scope, set it for this item (Selection.csv, Partners or Features); to change it, use Merge or Replace."
            }
        }
        # Other levels of the same feature already allowed in this policy.
        $others = @($policyCaps | Where-Object { $_.Feature -eq $cap.Feature -and $_.Name -ine $cap.Capability -and $_.IsAllowed -and -not $desiredNames.ContainsKey("$($cap.Target)|$($cap.PartnerTenantId)|$($_.Name)".ToLowerInvariant()) })
        foreach ($o in $others) {
            if ($Settings.Apply.DisableOtherLevels) { continue }
            $notes.Add("$($o.Name) is also allowed in this policy ($(Format-XsmLiveScope $o $groupNames)) and is kept (Apply.DisableOtherLevels = `$false).")
        }
        $scopeText = (@($cap.Specs | ForEach-Object { if ($_.Kind -eq 'All') { 'All users' } else { $_.DisplayName, $_.Id | Where-Object { $_ } | Select-Object -First 1 } }) -join ' + ')
        if (@($extra).Count) { $scopeText = ((@($scopeText) + @($extra | ForEach-Object { if ($_.ResourceId -ieq 'All') { 'All users' } elseif ($groupNames.ContainsKey(([string]$_.ResourceId).ToLowerInvariant())) { $groupNames[([string]$_.ResourceId).ToLowerInvariant()] } else { "$($_.ResourceType) $($_.ResourceId)" } })) -join ' + ') + ' (merged)' }
        $actions.Add((New-XsmAction @{
                    Key = "capability|$($cap.Key)"; Phase = 'Exchange'; Kind = 'Capability'; Operation = $op; InPhase = $exchangeIn; Status = (& $statusOf $op $exchangeIn)
                    Target = $(if ($cap.Target -eq 'Default') { 'Default policy' } else { $cap.PartnerName }); PartnerTenantId = $cap.PartnerTenantId; PartnerName = $cap.PartnerName
                    Feature = $cap.Feature; Capability = $cap.Capability; Before = $before; After = $scopeText; Detail = $detail; Notes = @($notes); ItemIds = @($cap.ItemIds)
                    Ref = $cap; ExtraScopes = @($extra)
                }))
        if ($Settings.Apply.DisableOtherLevels -and $op -ne 'Blocked') {
            foreach ($o in $others) {
                $actions.Add((New-XsmAction @{
                            Key = "disable|$($cap.Target)|$($cap.PartnerTenantId)|$($o.Name)".ToLowerInvariant(); Phase = 'Exchange'; Kind = 'Capability'; Operation = 'Disable'; InPhase = $exchangeIn; Status = (& $statusOf 'Disable' $exchangeIn)
                            Target = $(if ($cap.Target -eq 'Default') { 'Default policy' } else { $cap.PartnerName }); PartnerTenantId = $cap.PartnerTenantId; PartnerName = $cap.PartnerName
                            Feature = $cap.Feature; Capability = $o.Name; Before = (Format-XsmLiveScope $o $groupNames); After = 'not allowed (scope kept)'
                            Detail = "Other level of $($cap.Feature) set to not allowed (Apply.DisableOtherLevels = `$true)."
                            Ref = @{ Target = $cap.Target; PartnerTenantId = $cap.PartnerTenantId; Existing = $o }
                        }))
            }
        }
    }

    # The default policy trust is only reported: the tool never changes the default policy trust.
    if (@($Target.Capabilities | Where-Object Target -eq 'Default').Count -and $Live.Default.Trust.State -eq 'Blocked') {
        foreach ($a in @($actions | Where-Object { $_.Kind -eq 'Capability' -and $_.Target -eq 'Default policy' })) {
            $a.Notes = @($a.Notes) + 'Microsoft 365 collaboration is blocked in the default cross-tenant access policy (service default when never configured). The tool does not change the default trust: partners with their own Microsoft 365 collaboration trust are not affected; for the other tenants, follow the Microsoft guidance on default capabilities.'
        }
    }
    $i = 0
    foreach ($a in $actions) { $i++; $a.Id = '{0}{1:00}' -f $(if ($a.Phase -eq 'Entra') { 'E' } else { 'X' }), $i }
    return , $actions.ToArray()
}

function Show-XsmActions {
    <#
    .SYNOPSIS
        Console view of the actions, one section per phase.
    .PARAMETER Explanations
        Phase -> Get-XsmPhaseExplanation: shown in place of 'Nothing in this phase' when a phase has no action.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions, [string]$Phase = 'All', [System.Collections.IDictionary]$Explanations = @{})
    if (-not $Actions.Count) { Write-XsmItem Info 'Nothing to configure: no item is migrated (reasons at step 2).'; return }
    foreach ($p in 'Entra', 'Exchange') {
        $rows = @($Actions | Where-Object Phase -eq $p)
        $title = if ($p -eq 'Entra') { 'Phase Entra  -  security groups, Microsoft 365 collaboration trust' } else { 'Phase Exchange  -  Free/Busy, MailTips, calendar sharing capabilities' }
        $inPhase = $Phase -in $p, 'All'
        Write-XsmSection ($title + $(if (-not $inPhase) { '   (other phase: shown for information)' })) -Icon $(if ($p -eq 'Entra') { 'Key' } else { 'Exchange' })
        if (-not $rows.Count) {
            if ($Explanations.Contains($p)) {
                foreach ($line in $Explanations[$p].Lines) { Write-XsmItem Info $line -Indent 8 }
                if ($Explanations[$p].Next) { Write-XsmItem Info "Next: $($Explanations[$p].Next)" -Icon Apply -Indent 8 }
            }
            else { Write-XsmItem Skip 'Nothing in this phase.' -Indent 8 }
            continue
        }
        $view = foreach ($a in $rows) {
            $status = switch ($a.Operation) { 'NoChange' { 'Skip' } { $_ -in 'Blocked', 'Conflict' } { 'Fail' } default { if ($a.Status -eq 'OtherPhase') { 'Skip' } else { 'Info' } } }
            $icon = switch ($a.Operation) { 'Create' { 'Create' } 'Update' { 'Update' } 'AddMembers' { 'Create' } 'Disable' { 'Update' } 'NoChange' { 'Same' } default { 'Block' } }
            $what = switch ($a.Kind) { 'Group' { 'security group' } 'Trust' { 'M365 collaboration trust' } default { $a.Capability } }
            $change = if ($a.Operation -eq 'NoChange') { "in place: $($a.After)" } elseif ($a.Operation -in 'Blocked', 'Conflict') { $a.Detail } else { "$($a.Before) $($script:Arrow) $($a.After)" }
            if (@($a.Notes).Count) { $change += "  ($(@($a.Notes)[0]))" }
            [pscustomobject]@{ Status = $status; Icon = $icon; Id = $a.Id; Operation = $a.Operation; What = $what; Target = $a.Target; Change = $change }
        }
        Write-XsmTable -Columns @(@{ Name = 'Id'; Property = 'Id'; Width = 4 }, @{ Name = 'Operation'; Property = 'Operation'; Width = 10 }, @{ Name = 'What'; Property = 'What'; Width = 44 }, @{ Name = 'Target'; Property = 'Target'; Width = 24 }, @{ Name = 'Change'; Property = 'Change'; Width = 0 }) -Rows @($view) -IconProperty Icon -Indent 8
    }
}

function Get-XsmActionCounts {
    param([AllowEmptyCollection()][object[]]$Actions = @())
    $count = { param($filter) @($Actions | Where-Object $filter).Count }
    [ordered]@{
        EntraToDo       = & $count { $_.Phase -eq 'Entra' -and $_.Operation -in 'Create', 'Update', 'AddMembers' -and $_.Status -ne 'Blocked' }
        ExchangeToDo    = & $count { $_.Phase -eq 'Exchange' -and $_.Operation -in 'Create', 'Update', 'Disable' -and $_.Status -ne 'Blocked' }
        InPhaseToDo     = & $count { $_.Status -eq 'ToDo' }
        NoChange        = & $count { $_.Operation -eq 'NoChange' }
        NoChangeInPhase = & $count { $_.Operation -eq 'NoChange' -and $_.InPhase }
        Blocked         = & $count { $_.Operation -in 'Blocked', 'Conflict' }
        BlockedInPhase  = & $count { $_.Operation -in 'Blocked', 'Conflict' -and $_.InPhase }
        Done            = & $count { $_.Status -eq 'Done' }
        Failed          = & $count { $_.Status -eq 'Failed' }
        Skipped         = & $count { $_.Status -eq 'Skipped' }
    }
}

function Get-XsmPhaseExplanation {
    <#
    .SYNOPSIS
        Why one phase has nothing to change, in plain words, and what to run next - or $null when the phase
        has something to change.
    .OUTPUTS
        Reason (NoItem | NotNeeded | InPlace | Blocked), Short (one line, summary card), Lines (console and
        report), Next (command or step to run next, '' when none).
    #>
    param([Parameter(Mandatory)]$Target, [AllowEmptyCollection()][object[]]$Actions = @(), [Parameter(Mandatory)][ValidateSet('Entra', 'Exchange')][string]$Phase)
    $writes = @{ Entra = @('Create', 'Update', 'AddMembers'); Exchange = @('Create', 'Update', 'Disable') }
    $mine = @($Actions | Where-Object Phase -eq $Phase)
    if (@($mine | Where-Object { $_.Operation -in $writes[$Phase] }).Count) { return $null }
    $other = if ($Phase -eq 'Entra') { 'Exchange' } else { 'Entra' }
    $otherToDo = @($Actions | Where-Object { $_.Phase -eq $other -and $_.Operation -in $writes[$other] }).Count
    $caps = @($Target.Capabilities)
    $blocked = @($mine | Where-Object { $_.Operation -in 'Blocked', 'Conflict' })
    $result = { param($Reason, $Short, $Lines, $Next) [pscustomobject]@{ Phase = $Phase; Reason = $Reason; Short = $Short; Lines = @($Lines); Next = $Next } }
    $nextOther = if ($otherToDo) { ".\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase $other   ($otherToDo change(s) in phase $other)" } else { '' }

    if (-not $caps.Count) {
        return & $result 'NoItem' 'no item is migrated (reasons at step 2)' @('No item is migrated, so there is nothing to configure: the reasons are at step 2 (Building the target configuration).') ''
    }
    if ($blocked.Count) {
        $next = if ($Phase -eq 'Exchange' -and @($blocked | Where-Object { $_.Detail -match 'Phase Entra first' }).Count -and $otherToDo) { ".\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Entra first   ($otherToDo change(s))" } else { 'fix the blocked actions (Detail column, Annex A of the guide), then run again' }
        return & $result 'Blocked' "$($blocked.Count) action(s) blocked or in conflict, nothing else to change" @("Nothing can be changed in phase ${Phase}: $($blocked.Count) action(s) blocked or in conflict (see the Detail of each action).") $next
    }
    if ($Phase -eq 'Entra' -and -not $mine.Count) {
        # No trust and no group: every capability is in the default policy, scoped to All users.
        $what = @($caps | ForEach-Object { if ($_.Feature -eq 'AnonymousCalendarSharing') { 'anonymous calendar publishing (Anonymous:...)' } else { 'calendar sharing with every external organization (*:...)' } } | Select-Object -Unique)
        $lines = @(
            "Nothing to do in Microsoft Entra ID for this migration: the $($caps.Count) capabilit(ies) - $($what -join ', ') - go to the DEFAULT cross-tenant access policy, for All users."
            'Phase Entra only creates the Microsoft 365 collaboration trust of a named partner tenant (organization relationship, domain entry of a sharing policy) and the security groups used as scopes: Anonymous and * entries of a sharing policy, for All users, need neither.'
        )
        return & $result 'NotNeeded' 'not needed - only default-policy capabilities for All users (Anonymous / * sharing entries): no partner trust, no security group' $lines $(if ($nextOther) { "$nextOther - Exchange Administrator" } else { 'nothing to change in phase Exchange either: manual cutover (ManualCutover.txt)' })
    }
    if ($Phase -eq 'Entra') {
        $list = @($mine | ForEach-Object { if ($_.Kind -eq 'Trust') { "trust of $($_.PartnerName)" } else { "group $($_.Target)" } })
        $text = (@($list | Select-Object -First 5) -join ', ') + $(if ($list.Count -gt 5) { " and $($list.Count - 5) more" } else { '' })
        return & $result 'InPlace' "already in place - $text" @("Everything phase Entra needs is already in place: $text.") $(if ($nextOther) { $nextOther } else { 'nothing to change in phase Exchange either: manual cutover (ManualCutover.txt)' })
    }
    return & $result 'InPlace' "already in place - $($caps.Count) capabilit(ies) configured as planned" @("Every capability is already configured in Microsoft 365 X-TAP as planned ($($caps.Count)).") $(if ($nextOther) { $nextOther } else { 'manual cutover (ManualCutover.txt)' })
}
