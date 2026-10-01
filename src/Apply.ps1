<#
    X-TAP Sharing Migration - apply.

    Executes the actions of the requested phase, in order: security groups, Microsoft 365 collaboration
    trusts (Entra), then capabilities (Exchange). An action that depends on a failed action is skipped.
    Every call is Microsoft Graph v1.0. Nothing is ever deleted: Disable sets isAllowed = false.
#>

$script:RetryDelaySeconds = 15

function Invoke-XsmGraphWithRetry {
    <#
    .SYNOPSIS
        Graph call with retries: always on 429 / 5xx; also on 400 / 404 when the call depends on an object
        created a few seconds earlier by this execution (replication in Microsoft Entra ID).
    #>
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Uri, $Body, [switch]$DependsOnNewObject, [int]$Attempts = 4)
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-XsmGraph -Method $Method -Uri $Uri -Body $Body }
        catch {
            $status = Get-XsmGraphErrorStatus $_
            $retry = $status -eq 429 -or $status -ge 500 -or ($DependsOnNewObject -and $status -in 400, 404)
            if (-not $retry -or $attempt -ge $Attempts) { throw }
            $wait = $script:RetryDelaySeconds * $attempt
            Write-XsmLog 'WARN' "Graph $Method $Uri - HTTP $status, new attempt in $wait s ($attempt/$Attempts)"
            Start-Sleep -Seconds $wait
        }
    }
}

function New-XsmCapabilityBody {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$IsAllowed, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Included, [object[]]$Excluded = @())
    $included = @(foreach ($s in $Included) { @{ resourceId = [string]$s.ResourceId; resourceType = [string]$s.ResourceType } })
    $excluded = @(foreach ($s in $Excluded) { @{ resourceId = [string]$s.ResourceId; resourceType = [string]$s.ResourceType } })
    return @{
        '@odata.type' = "#microsoft.graph.$Name"
        inboundAccess = @{ isAllowed = $IsAllowed; resourceScopes = @{ included = $included; excluded = $excluded } }
    }
}

function Get-XsmTrustBody {
    return @{ users = @{ accessType = 'allowed'; targets = @(@{ target = 'AllUsers'; targetType = 'user' }) } }
}

function Add-XsmGroupMembers {
    <# Adds members to a group, 20 per request; members already present are ignored. Returns the number added. #>
    param([Parameter(Mandatory)][string]$GroupId, [AllowEmptyCollection()][string[]]$MemberIds = @(), [switch]$NewGroup)
    $added = 0
    for ($i = 0; $i -lt $MemberIds.Count; $i += 20) {
        $batch = @($MemberIds[$i..([Math]::Min($i + 19, $MemberIds.Count - 1))])
        $body = @{ 'members@odata.bind' = @($batch | ForEach-Object { "$($script:GraphRoot)/directoryObjects/$_" }) }
        try {
            Invoke-XsmGraphWithRetry -Method PATCH -Uri "/groups/$GroupId" -Body $body -DependsOnNewObject:$NewGroup | Out-Null
            $added += $batch.Count
        } catch {
            # One member already present (or deleted since the collection) fails the whole batch: add them one by one.
            foreach ($id in $batch) {
                try {
                    Invoke-XsmGraphWithRetry -Method POST -Uri "/groups/$GroupId/members/`$ref" -Body @{ '@odata.id' = "$($script:GraphRoot)/directoryObjects/$id" } | Out-Null
                    $added++
                } catch {
                    if ($_.Exception.Message -notmatch 'already exist') { Write-XsmLog 'WARN' "Member $id not added to $($GroupId): $($_.Exception.Message)" }
                }
            }
        }
    }
    return $added
}

function Invoke-XsmActions {
    <#
    .SYNOPSIS
        Executes the actions with Status ToDo. Updates Status (Done | Failed | Skipped), Error and Detail of
        each action, and returns the object IDs of the groups created (group key -> ID).
    #>
    param([Parameter(Mandatory)][object[]]$Actions, [Parameter(Mandatory)]$Live)
    $groupIds = @{}
    foreach ($key in $Live.Groups.Keys) { if ($Live.Groups[$key].Found) { $groupIds[$key] = $Live.Groups[$key].Id } }
    $failedGroups = @{}; $failedTrusts = @{}; $newGroups = @{}; $newTrusts = @{}
    $C = $script:C
    foreach ($a in $Actions) {
        if ($a.Status -ne 'ToDo') { continue }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            switch ($a.Kind) {
                'Group' {
                    $req = $a.Ref
                    if ($a.Operation -eq 'Create') {
                        $body = @{ displayName = $req.DisplayName; description = $req.Description; mailEnabled = $false; mailNickname = $req.MailNickname; securityEnabled = $true }
                        if ($req.MembershipRule) { $body.groupTypes = @('DynamicMembership'); $body.membershipRule = $req.MembershipRule; $body.membershipRuleProcessingState = 'On' }
                        $created = Invoke-XsmGraphWithRetry -Method POST -Uri '/groups' -Body $body
                        $id = ([string]$created['id']).ToLowerInvariant()
                        $groupIds[$req.Key] = $id; $newGroups[$req.Key] = $true
                        $a.After = "$($req.DisplayName) ($id)"
                        if ($req.Kind -eq 'SharingPolicy' -and $req.MemberIds.Count) {
                            $n = Add-XsmGroupMembers -GroupId $id -MemberIds $req.MemberIds -NewGroup
                            $a.Detail = "Created with $n of $($req.MemberIds.Count) member(s)"
                        } else { $a.Detail = 'Created' }
                    } elseif ($a.Operation -eq 'AddMembers') {
                        $n = Add-XsmGroupMembers -GroupId $groupIds[$req.Key] -MemberIds @($req.MissingIds)
                        $a.Detail = "$n member(s) added"
                    }
                }
                'Trust' {
                    $t = $a.Ref
                    if ($a.Operation -eq 'Create') {
                        Invoke-XsmGraphWithRetry -Method POST -Uri '/policies/crossTenantAccessPolicy/partners' -Body @{ tenantId = $t.TenantId; m365CollaborationInbound = (Get-XsmTrustBody) } | Out-Null
                    } else {
                        Invoke-XsmGraphWithRetry -Method PATCH -Uri "/policies/crossTenantAccessPolicy/partners/$($t.TenantId)" -Body @{ m365CollaborationInbound = (Get-XsmTrustBody) } | Out-Null
                    }
                    $newTrusts[$t.TenantId] = $true
                }
                'Capability' {
                    if ($a.Operation -eq 'Disable') {
                        $r = $a.Ref
                        $body = New-XsmCapabilityBody -Name $r.Existing.Name -IsAllowed $false -Included @($r.Existing.Included) -Excluded @($r.Existing.Excluded)
                        Invoke-XsmGraphWithRetry -Method PATCH -Uri "$(Get-XsmPolicyPath $r.Target $r.PartnerTenantId)/$($r.Existing.Name)" -Body $body | Out-Null
                        break
                    }
                    $cap = $a.Ref
                    if ($cap.Target -eq 'Partner' -and $failedTrusts.ContainsKey($cap.PartnerTenantId)) { throw (New-XsmSkipException 'the Microsoft 365 collaboration trust of this partner failed') }
                    $included = [Collections.Generic.List[object]]::new()
                    $dependsOnNew = $cap.Target -eq 'Partner' -and $newTrusts.ContainsKey($cap.PartnerTenantId)
                    foreach ($spec in $cap.Specs) {
                        if ($spec.Kind -eq 'All') { $included.Add(@{ ResourceId = 'All'; ResourceType = 'user' }); continue }
                        $gk = Get-XsmGroupRequirementKey $spec
                        if ($failedGroups.ContainsKey($gk) -or -not $groupIds.ContainsKey($gk)) { throw (New-XsmSkipException "the scope group '$(Format-XsmScope @($spec))' is not available") }
                        if ($newGroups.ContainsKey($gk)) { $dependsOnNew = $true }
                        $included.Add(@{ ResourceId = $groupIds[$gk]; ResourceType = 'group' })
                    }
                    foreach ($x in @($a.ExtraScopes)) { if ($x) { $included.Add(@{ ResourceId = [string]$x.ResourceId; ResourceType = [string]$x.ResourceType }) } }
                    # "All" covers every other resource of the scope.
                    $all = @($included | Where-Object { $_.ResourceId -ieq 'All' })
                    if ($all.Count) { $included = [Collections.Generic.List[object]]::new(); $included.Add($all[0]) }
                    $body = New-XsmCapabilityBody -Name $cap.Capability -IsAllowed $true -Included $included.ToArray()
                    $path = Get-XsmPolicyPath $cap.Target $cap.PartnerTenantId
                    if ($a.Operation -eq 'Create') { Invoke-XsmGraphWithRetry -Method POST -Uri $path -Body $body -DependsOnNewObject:$dependsOnNew | Out-Null }
                    else { Invoke-XsmGraphWithRetry -Method PATCH -Uri "$path/$($cap.Capability)" -Body $body -DependsOnNewObject:$dependsOnNew | Out-Null }
                }
            }
            $a.Status = 'Done'
            Write-XsmItem Ok ("{0}  {1,-10} {2,-11} {3}{4}" -f $a.Id, $a.Operation, $a.Kind, $a.Target, $(if ($a.Capability) { "  $($script:Dot) $($a.Capability)" })) -Indent 8
        } catch {
            if ($_.Exception.Data.Contains('XsmSkip')) {
                $a.Status = 'Skipped'; $a.Error = "Not done: $($_.Exception.Message)."
                Write-XsmItem Skip ("{0}  {1}: {2}" -f $a.Id, $a.Target, $a.Error) -Indent 8
                continue
            }
            $a.Status = 'Failed'; $a.Error = $_.Exception.Message
            if ($a.Kind -eq 'Group') { $failedGroups[$a.Ref.Key] = $true }
            if ($a.Kind -eq 'Trust') { $failedTrusts[$a.Ref.TenantId] = $true }
            Write-XsmItem Fail ("{0}  {1} {2} {3}: {4}" -f $a.Id, $a.Operation, $a.Kind, $a.Target, $a.Error) -Indent 8
            $hint = Get-XsmPermissionHint $a $_
            if ($hint) { Write-XsmItem Info $hint -Indent 12; $a.Error += " $hint" }
        }
        Write-XsmLog 'DEBUG' ("{0} done in {1:0.0} s" -f $a.Id, $clock.Elapsed.TotalSeconds)
    }
    return $groupIds
}

function New-XsmSkipException {
    <# Exception that marks an action as Skipped (it depends on an action that failed). #>
    param([Parameter(Mandatory)][string]$Message)
    $e = [InvalidOperationException]::new($Message)
    $e.Data['XsmSkip'] = $true
    return $e
}

function Get-XsmPermissionHint {
    <# Role needed when Graph answers 401/403. #>
    param($Action, $ErrorRecord)
    $status = Get-XsmGraphErrorStatus $ErrorRecord
    if ($status -notin 401, 403) { return '' }
    switch ($Action.Kind) {
        'Group' { return 'Role needed: Groups Administrator (or Global Administrator), permission Group.ReadWrite.All.' }
        'Trust' { return 'Role needed: Security Administrator (or Global Administrator), permission Policy.ReadWrite.CrossTenantAccess.' }
        'Capability' { return 'Role needed: Exchange Administrator (Free/Busy, MailTips, calendar sharing) or Global Administrator, permission Policy.ReadWrite.CrossTenantCapability.' }
    }
    return ''
}

function Set-XsmVerification {
    <#
    .SYNOPSIS
        After Apply: compares the actions done with the tenant read again. An action is Verified when the
        same comparison now gives NoChange (or, for groups, when the group exists).
    #>
    param([Parameter(Mandatory)][object[]]$Actions, [Parameter(Mandatory)][object[]]$After)
    $byKey = @{}
    foreach ($a in $After) { $byKey[$a.Key] = $a }
    foreach ($a in $Actions) {
        if ($a.Status -ne 'Done') { continue }
        $now = $byKey[$a.Key]
        if (-not $now) { $a.Verified = $(if ($a.Operation -eq 'Disable') { 'Verified' } else { 'Not found' }); continue }
        if ($now.Operation -eq 'NoChange' -or ($a.Operation -eq 'Disable' -and $now.Operation -ne 'Disable')) { $a.Verified = 'Verified' }
        elseif ($a.Kind -eq 'Group' -and $now.Operation -eq 'AddMembers') { $a.Verified = 'Verified (member list still replicating)' }
        else { $a.Verified = "Not verified: $($now.Operation) still needed" }
    }
}
