<#
    X-TAP Sharing Migration - report files.

    - HTML report (templates\Report.template.html): one self-contained file per execution, with the
      data embedded as JSON. Collect = inventory (initial picture); Plan = what would be done;
      Apply = what was done and verified.
    - CSV files: Selection.csv (Collect), Plan.csv / Result.csv (Plan / Apply).
    - Manual cutover commands (ManualCutover.txt and in the HTML report): the tool never runs them.
#>

function ConvertTo-XsmQuoted {
    param([AllowEmptyString()][string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

function Get-XsmCutover {
    <#
    .SYNOPSIS
        Manual cutover commands for the Exchange Online objects whose items are migrated, with the rollback
        commands, and the list of partners to coordinate with. The tool never runs these commands.
    #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Target)
    $included = @{}
    foreach ($d in @($Target.Decisions)) { if ($d.Decision.Include -and -not @($d.Decision.Problems).Count) { $included[[string]$d.Item.ItemId] = $d } }
    $steps = [Collections.Generic.List[object]]::new()
    $exchange = $Snapshot.Exchange
    $backup = Join-Path $Snapshot.Directory 'backup'

    # Organization relationships
    $n = 0
    foreach ($o in @($exchange.OrganizationRelationships)) {
        $n++
        $mine = @($Snapshot.Items | Where-Object { $_.Source -eq 'OrganizationRelationship' -and $_.SourceName -eq $o.Name })
        $migrated = @($mine | Where-Object { $included.ContainsKey([string]$_.ItemId) })
        if (-not $migrated.Count) { continue }
        $warnings = @()
        $notMigrated = @($mine | Where-Object { -not $included.ContainsKey([string]$_.ItemId) } | ForEach-Object { "$($_.Feature) ($($_.PartnerName))" } | Select-Object -Unique)
        if ($notMigrated.Count) { $warnings += "Disabling the relationship also stops what is not migrated: $($notMigrated -join ', '). Migrate these features too before the cutover of this relationship, or keep the relationship until then." }
        $otherUses = @(foreach ($p in 'MailboxMoveEnabled', 'ArchiveAccessEnabled', 'DeliveryReportEnabled', 'PhotosEnabled') { if ($o[$p]) { $p -replace 'Enabled$', '' } })
        if ($otherUses.Count) { $warnings += "The relationship is also used for $($otherUses -join ', '): move these uses to another organization relationship before disabling it (Microsoft guidance)." }
        $id = ConvertTo-XsmQuoted $o.Name
        $steps.Add([ordered]@{
                Source = 'Organization relationship'; Name = $o.Name
                Partners = @($migrated | ForEach-Object { $_.PartnerName } | Select-Object -Unique)
                Features = @($migrated | ForEach-Object { $_.Feature } | Select-Object -Unique)
                Commands = @("Set-OrganizationRelationship -Identity $id -Enabled `$false")
                Rollback = @("Set-OrganizationRelationship -Identity $id -Enabled `$true")
                Cleanup  = @("Remove-OrganizationRelationship -Identity $id -Confirm:`$false")
                Warnings = $warnings
            })
    }

    # Availability address spaces
    foreach ($a in @($exchange.AvailabilityAddressSpaces)) {
        $mine = @($Snapshot.Items | Where-Object { $_.Source -eq 'AvailabilityAddressSpace' -and $_.SourceName -eq $a.ForestName })
        # Removed once the partner has configured its side (PartnerSide), or when the item is migrated here (forced).
        $migrated = @($mine | Where-Object { $included.ContainsKey([string]$_.ItemId) -or $_.Reason -eq 'PartnerSide' })
        if (-not $migrated.Count) { continue }
        $partnerSide = @($migrated | Where-Object { $_.Reason -eq 'PartnerSide' -and -not $included.ContainsKey([string]$_.ItemId) }).Count
        $id = ConvertTo-XsmQuoted $a.ForestName
        $file = ConvertTo-XsmQuoted ".\AvailabilityAddressSpace_$($a.ForestName).xml"
        $warnings = @("An availability address space cannot be disabled: it is removed (a copy is also in $backup).")
        if ($partnerSide) { $warnings = @("Remove it only after the partner has allowed crossTenantCalendarAvailabilityBasic for your tenant ID ($($Snapshot.Tenant.TenantId)): until then your users would lose its free/busy.") + $warnings }
        $steps.Add([ordered]@{
                Source = 'Availability address space'; Name = $a.ForestName
                Partners = @($migrated | ForEach-Object { $_.PartnerName } | Select-Object -Unique); Features = @('FreeBusy')
                Commands = @("Get-AvailabilityAddressSpace -Identity $id | Export-Clixml $file", "Remove-AvailabilityAddressSpace -Identity $id -Confirm:`$false")
                Rollback = @(
                    "Import-Clixml $file | ForEach-Object {",
                    "  `$p = @{ ForestName = `$_.ForestName; AccessMethod = `$_.AccessMethod }",
                    "  foreach (`$n in 'ProxyUrl', 'TargetAutodiscoverEpr', 'TargetServiceEpr', 'TargetTenantId') { if (-not [string]::IsNullOrEmpty(`$_.`$n)) { `$p[`$n] = `$_.`$n } }",
                    "  Add-AvailabilityAddressSpace @p",
                    "}")
                Cleanup  = @()
                Warnings = $warnings
            })
    }

    # Sharing policies
    $n = 0
    foreach ($p in @($exchange.SharingPolicies)) {
        $n++
        $mine = @($Snapshot.Items | Where-Object { $_.Source -eq 'SharingPolicy' -and $_.SourceName -eq $p.Name })
        $migrated = @($mine | Where-Object { $included.ContainsKey([string]$_.ItemId) })
        if (-not $migrated.Count) { continue }
        $remaining = [Collections.Generic.List[string]]::new()
        $m = 0
        foreach ($entry in @($p.Domains)) {
            $m++
            $itemId = 'SP{0:00}-{1:00}' -f $n, $m
            if (-not $included.ContainsKey($itemId)) { $remaining.Add($entry); continue }
            $parsed = ConvertFrom-XsmSharingEntry $entry
            if ($parsed.Other.Count) {
                $domain = switch ($parsed.Kind) { 'Anonymous' { 'Anonymous' } 'Wildcard' { '*' } default { $(if ($parsed.Subdomains) { "*.$($parsed.Domain)" } else { $parsed.Domain }) } }
                $remaining.Add("$($domain):$($parsed.Other -join ', ')")
            }
        }
        $id = ConvertTo-XsmQuoted $p.Name
        $original = (@($p.Domains) | ForEach-Object { ConvertTo-XsmQuoted $_ }) -join ', '
        $commands = if ($remaining.Count) { @("Set-SharingPolicy -Identity $id -Domains $((@($remaining) | ForEach-Object { ConvertTo-XsmQuoted $_ }) -join ', ')") } else { @("Set-SharingPolicy -Identity $id -Enabled `$false") }
        $rollback = @("Set-SharingPolicy -Identity $id -Domains $original")
        if (-not $remaining.Count) { $rollback += "Set-SharingPolicy -Identity $id -Enabled `$true" }
        $warnings = @()
        if ($remaining.Count) { $warnings += "Entries kept (not migrated): $(@($remaining) -join ' | ')." }
        if ($p.Default -and -not $remaining.Count) { $warnings += 'Default sharing policy: disabling it stops calendar sharing for every mailbox that uses it - the X-TAP capabilities take over.' }
        $steps.Add([ordered]@{
                Source = 'Sharing policy'; Name = $p.Name
                Partners = @($migrated | ForEach-Object { $_.PartnerName } | Select-Object -Unique)
                Features = @($migrated | ForEach-Object { $_.Feature } | Select-Object -Unique)
                Commands = @($commands); Rollback = @($rollback)
                Cleanup  = @(if (-not $remaining.Count -and -not $p.Default) { "Remove-SharingPolicy -Identity $id -Confirm:`$false" })
                Warnings = $warnings
            })
    }

    $partners = [Collections.Generic.List[object]]::new()
    foreach ($set in @($Target.Capabilities | Where-Object Target -eq 'Partner' | Group-Object { $_.PartnerTenantId })) {
        $partners.Add([ordered]@{
                TenantId          = $set.Name
                Name              = $set.Group[0].PartnerName
                Domains           = @($set.Group | ForEach-Object { $_.PartnerDomains } | Select-Object -Unique)
                Capabilities      = @($set.Group | ForEach-Object { $_.Capability })
                PartnerConfigures = @()
            })
    }
    # Availability address spaces: the partner configures X-TAP on its side for this tenant.
    foreach ($item in @($Snapshot.Items | Where-Object { $_.Reason -eq 'PartnerSide' -and $_.PartnerTenantId })) {
        $p = @($partners | Where-Object TenantId -eq ([string]$item.PartnerTenantId).ToLowerInvariant()) | Select-Object -First 1
        if (-not $p) {
            $p = [ordered]@{ TenantId = ([string]$item.PartnerTenantId).ToLowerInvariant(); Name = $item.PartnerName; Domains = @($item.PartnerDomains); Capabilities = @(); PartnerConfigures = @() }
            $partners.Add($p)
        }
        $p.PartnerConfigures = @($p.PartnerConfigures) + "crossTenantCalendarAvailabilityBasic for your tenant ID (replaces the availability address space $($item.SourceName))"
    }
    [ordered]@{ OwnTenantId = [string]$Snapshot.Tenant.TenantId; Steps = $steps.ToArray(); Partners = $partners.ToArray(); HasDefault = [bool]@($Target.Capabilities | Where-Object Target -eq 'Default').Count }
}

function Export-XsmCutoverText {
    <# ManualCutover.txt: the commands of the manual cutover, by Exchange object, with the rollback. #>
    param([Parameter(Mandatory)]$Cutover, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Settings)
    $sb = [Text.StringBuilder]::new()
    $line = { param($t) [void]$sb.AppendLine($t) }
    & $line '# ================================================================================================'
    & $line "# $($script:ToolName) $($script:ToolVersion) - MANUAL CUTOVER (not run by the tool)"
    & $line "# Tenant $($Settings.Tenant.TenantId) $($Settings.Tenant.Organization)"
    & $line '#'
    & $line '# Organization relationships, availability address spaces and sharing policies take precedence over'
    & $line '# Microsoft 365 X-TAP. Run these commands in Exchange Online PowerShell during a window agreed with the'
    & $line '# administrators of the partner tenants (they disable their side at the same time), then test.'
    & $line '# Keep the rollback commands at hand. Remove the old objects only after validation (cleanup).'
    & $line '# ================================================================================================'
    if (-not $Cutover.Steps.Count) { & $line ''; & $line '# Nothing to cut over: no Exchange object is migrated.' }
    foreach ($s in $Cutover.Steps) {
        & $line ''
        & $line "# --- $($s.Source): $($s.Name)  ($(@($s.Features) -join ', ') - $(@($s.Partners) -join ', '))"
        foreach ($w in @($s.Warnings)) { & $line "# WARNING: $w" }
        & $line '# Cutover'
        foreach ($c in @($s.Commands)) { & $line $c }
        & $line '# Rollback'
        foreach ($c in @($s.Rollback)) { & $line "# $c" }
        if (@($s.Cleanup).Count) { & $line '# Cleanup, after validation'; foreach ($c in @($s.Cleanup)) { & $line "# $c" } }
    }
    if ($Cutover.Partners.Count) {
        & $line ''
        & $line '# --- Partners to coordinate with (X-TAP is inbound: each partner allows YOUR tenant on its side)'
        & $line "#     Your tenant ID: $($Cutover.OwnTenantId)"
        foreach ($p in $Cutover.Partners) {
            & $line "#     $($p.Name)  $($p.TenantId)  ($(@($p.Domains) -join ', '))"
            foreach ($x in @($p.PartnerConfigures)) { & $line "#         the partner configures on its side: $x" }
        }
    }
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($true))
}

function Export-XsmActionsCsv {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Settings)
    $rows = foreach ($a in $Actions) {
        [pscustomobject][ordered]@{
            Id = $a.Id; Phase = $a.Phase; Kind = $a.Kind; Operation = $a.Operation; Status = $a.Status; Verified = $a.Verified
            Target = $a.Target; PartnerTenantId = $a.PartnerTenantId; Feature = $a.Feature; Capability = $a.Capability
            Before = $a.Before; After = $a.After; Detail = $a.Detail; Notes = (@($a.Notes) -join ' | '); Items = (@($a.ItemIds) -join ' '); Error = $a.Error
        }
    }
    $text = if ($rows) { ($rows | ConvertTo-Csv -Delimiter $Settings.Output.CsvDelimiter -NoTypeInformation -UseQuotes AsNeeded) -join "`r`n" } else { 'Id' }
    [IO.File]::WriteAllText($Path, $text + "`r`n", [Text.UTF8Encoding]::new($true))
}

function ConvertTo-XsmReportAction {
    <# Action without its internal reference, for the JSON of the report. #>
    param([Parameter(Mandatory)]$Action)
    $copy = [ordered]@{}
    foreach ($k in $Action.Keys) { if ($k -notin 'Ref') { $copy[$k] = $Action[$k] } }
    return $copy
}

function ConvertTo-XsmReportTarget {
    param($Target)
    if (-not $Target) { return $null }
    [ordered]@{
        Capabilities = @($Target.Capabilities | ForEach-Object { [ordered]@{ Target = $_.Target; PartnerName = $_.PartnerName; PartnerTenantId = $_.PartnerTenantId; Feature = $_.Feature; Level = $_.Level; Capability = $_.Capability; Scope = (Format-XsmScope $_.Specs); ItemIds = @($_.ItemIds) } })
        Groups       = @($Target.Groups | ForEach-Object { [ordered]@{ Key = $_.Key; Kind = $_.Kind; DisplayName = $_.DisplayName; Id = $_.Id; Create = $_.Create; MembershipRule = $_.MembershipRule; Policy = $_.Policy; Members = @($_.MemberIds).Count } })
        Trusts       = @($Target.Trusts)
        Warnings     = @($Target.Warnings)
    }
}

function Get-XsmPartnerSummary {
    <#
    .SYNOPSIS
        One row per partner tenant of the items in scope or configured by the partner (PartnerSide), with the
        confirmation of its tenant ID and what the partner must configure on its side.
    #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Settings)
    $aas = @($Snapshot.Exchange.AvailabilityAddressSpaces | ForEach-Object { [string]$_.TargetTenantId } | Where-Object { $_ })
    $existing = @($Snapshot.Xtap.Partners | ForEach-Object { [string]$_.TenantId })
    return @($Snapshot.Items | Where-Object { $_.Status -eq 'InScope' -or $_.Reason -eq 'PartnerSide' } | Where-Object { $_.Target -eq 'Partner' -and $_.PartnerTenantId } | Group-Object { $_.PartnerTenantId } | ForEach-Object {
            $domains = @($_.Group | ForEach-Object { $_.PartnerDomains } | Select-Object -Unique | Sort-Object)
            $c = Get-XsmPartnerConfirmation -TenantId $_.Name -Domains $domains -Settings $Settings -AddressSpaceTenantIds $aas -PartnerPolicyExists:($_.Name -in $existing)
            $partnerSide = @($_.Group | Where-Object Reason -eq 'PartnerSide')
            [ordered]@{
                TenantId = $_.Name; Name = $_.Group[0].PartnerName; Domains = $domains
                Features = @($_.Group | Where-Object Status -eq 'InScope' | ForEach-Object { $_.Feature } | Select-Object -Unique)
                Sources  = @($_.Group | ForEach-Object { $_.SourceName } | Select-Object -Unique)
                Confirmation = $c.State; ConfirmationSource = $c.Source; ConfirmationDetail = $c.Detail
                PartnerConfigures = @($partnerSide | ForEach-Object { "crossTenantCalendarAvailabilityBasic for your tenant ID (replaces the availability address space $($_.SourceName))" } | Select-Object -Unique)
                PartnerSideOnly = ($partnerSide.Count -eq $_.Count)
            }
        })
}

function Export-XsmPartnerSnippet {
    <#
    .SYNOPSIS
        PartnersToConfirm.txt: the Partners entries to paste in the configuration, one per partner tenant,
        with the tenant ID found. The administrator sends the list to each partner, gets its tenant ID
        confirmed, and pastes the entries (correcting the tenant ID if the partner gives another one).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Partners, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Settings)
    $sb = [Text.StringBuilder]::new()
    $line = { param($t) [void]$sb.AppendLine($t) }
    & $line "# $($script:ToolName) $($script:ToolVersion) - partner tenants to confirm"
    & $line "# Tenant $($Settings.Tenant.TenantId) $($Settings.Tenant.Organization)"
    & $line '#'
    & $line '# The tenant IDs below were found from the domains of the partners (Microsoft Entra OpenID configuration).'
    & $line '# Before the Entra phase, have each partner confirm its tenant ID (Microsoft Entra admin center >'
    & $line '# Overview > Tenant ID), and give it your own tenant ID so it can configure its side.'
    & $line '# Then paste the entries in the Partners section of the configuration file.'
    & $line "#   Your tenant ID: $($Settings.Tenant.TenantId)"
    & $line ''
    & $line 'Partners = @('
    foreach ($p in $Partners) {
        $state = switch ($p.Confirmation) { 'Confirmed' { "already confirmed: $($p.ConfirmationSource)" } 'Mismatch' { "MISMATCH - $($p.ConfirmationDetail)" } default { 'TO CONFIRM with the partner' } }
        $what = if (@($p.Features).Count) { @($p.Features) -join ', ' } else { 'configured by the partner only' }
        & $line "    # $($p.Name) - $what - $state"
        foreach ($x in @($p.PartnerConfigures)) { & $line "    #   The partner configures on its side: $x" }
        & $line ("    @{{ Name = '{0}'; Match = '{1}'; TenantId = '{2}' }}" -f ([string]$p.Name).Replace("'", "''"), @($p.Domains)[0], $p.TenantId)
    }
    & $line ')'
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($true))
}

function ConvertTo-XsmReportItems {
    <#
    .SYNOPSIS
        Items of the snapshot with their decision (Include, Level, Scope and origins), for the report.
        Without -Decisions, the decision is the proposal of the configuration (Collect).
    #>
    param([AllowEmptyCollection()][object[]]$Items = @(), [Parameter(Mandatory)]$Settings, [object[]]$Decisions = @())
    $byId = @{}
    foreach ($d in $Decisions) { $byId[[string]$d.Item.ItemId] = $d }
    return , @(foreach ($item in $Items) {
            $entry = $byId[[string]$item.ItemId]
            $d = if ($entry) { $entry.Decision } else { Get-XsmItemDecision -Item $item -Settings $Settings }
            $row = [ordered]@{}
            foreach ($k in $item.Keys) { $row[$k] = $item[$k] }
            $row.Include = [bool]($d.Include -and -not @($d.Problems).Count)
            $row.IncludeOrigin = $d.IncludeOrigin
            $row.Level = $d.Level; $row.LevelOrigin = $d.LevelOrigin
            $row.Scope = $(if (-not $d.Scope) { '' } elseif ($d.Scope -eq [string]$item.DiscoveredScope -and $item.DiscoveredScopeText) { ([string]$item.DiscoveredScopeText) -replace '^group ', '' } else { Format-XsmScope (ConvertTo-XsmScopeSpec $d.Scope $Settings) }); $row.ScopeOrigin = $d.ScopeOrigin
            $row.Problems = @($d.Problems); $row.DecisionWarnings = @($d.Warnings)
            $row.Capability = $(if ($d.Level -and $item.Feature) { try { Get-XsmCapabilityName $item.Feature $d.Level } catch { '' } } else { '' })
            $row
        })
}

function ConvertTo-XsmReportXtap {
    <# State of the tenant read by Plan / Apply (before the changes), in the shape of the snapshot X-TAP state. #>
    param([Parameter(Mandatory)]$Live, $Target)
    $names = @{}
    foreach ($t in @($Target.Trusts)) { $names[$t.TenantId] = $t.PartnerName }
    [ordered]@{
        Readable = $true; Error = ''; ReadAt = $Live.ReadAt; Default = $Live.Default; GroupNames = $Live.GroupNames
        Partners = @(foreach ($tid in $Live.Partners.Keys) {
                $p = $Live.Partners[$tid]
                if ($p) { [ordered]@{ TenantId = $tid; Name = $names[$tid]; Trust = $p.Trust; Capabilities = @($p.Capabilities) } }
            })
    }
}

function New-XsmHtmlReport {
    <# Writes the HTML report: the template with the data embedded as JSON. #>
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Path, [string]$TemplatePath = (Join-Path $script:ToolRoot 'templates\Report.template.html'))
    if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Report template not found: $TemplatePath" }
    $template = [IO.File]::ReadAllText($TemplatePath)
    $marker = '/*XSM_DATA*/null'
    $count = ([regex]::Matches($template, [regex]::Escape($marker))).Count
    if ($count -ne 1) { throw "The report template must contain the marker $marker exactly once (found $count)." }
    $json = $Data | ConvertTo-Json -Depth 30 -Compress
    # Inside <script>: '</' would close the element; U+2028/U+2029 break some JavaScript parsers.
    $json = $json.Replace('</', '<\/').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
    [IO.File]::WriteAllText($Path, $template.Replace($marker, $json), [Text.UTF8Encoding]::new($false))
}

function New-XsmReportData {
    <# Common part of the report data. #>
    param([Parameter(Mandatory)][ValidateSet('Collect', 'Plan', 'Apply')][string]$Kind, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Snapshot, [string]$Phase = '')
    [ordered]@{
        Kind        = $Kind
        Phase       = $Phase
        Tool        = [ordered]@{ Name = $script:ToolName; Version = $script:ToolVersion; Author = $script:ToolAuthor }
        GeneratedAt = [DateTime]::UtcNow.ToString('o')
        TimeZone    = $Settings.Output.TimeZone
        Tenant      = $Snapshot.Tenant
        CollectId   = $Snapshot.CollectId
        CollectedAt = $Snapshot.CollectedAt
        Accounts    = [ordered]@{}
        Settings    = [ordered]@{
            RunFeatures         = @($Settings.RunFeatures)
            Features            = $Settings.Features
            Partners            = @($Settings.Partners)
            Groups              = $Settings.Groups
            SharingPolicyGroups = $Settings.SharingPolicyGroups
            Entra               = $Settings.Entra
            Apply               = $Settings.Apply
        }
    }
}
