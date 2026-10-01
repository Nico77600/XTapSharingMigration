#Requires -Version 7.4

<#
.SYNOPSIS
    X-TAP Sharing Migration - moves cross-tenant Free/Busy, MailTips and calendar sharing from Exchange
    Online (organization relationships, sharing policies, availability address spaces) to the Microsoft
    365 cross-tenant access policy (X-TAP), in two phases that different administrators can run.

.DESCRIPTION
    Three modes, in this order:

      1. COLLECT  Read-only. Reads Exchange Online and the Microsoft 365 cross-tenant access policy, finds the
                  Microsoft Entra tenant behind each external domain, and classifies every item: in scope
                  (external Microsoft 365 organization) or out of scope (Exchange hybrid, on-premises,
                  disabled ...). Writes the initial picture: Inventory.html, snapshot.json, Selection.csv,
                  and a backup of the Exchange objects.
      2. PLAN     Read-only. Builds the target configuration from the snapshot, the configuration file and,
                  optionally, Selection.csv completed by the administrator; compares it with the tenant and
                  writes Plan.html (actions, target, manual cutover commands).
      3. APPLY    Same comparison, confirmation, then the changes of one phase, and a verification:
                    -Phase Entra     security groups + Microsoft 365 collaboration trust of each partner
                                     (Security Administrator + Groups Administrator, or Global Administrator)
                    -Phase Exchange  Free/Busy, MailTips and calendar sharing capabilities
                                     (Exchange Administrator, or Global Administrator)
                    -Phase All       both, in one run.
                  Writes Result.html: what was put in place.

    The tool never changes an Exchange Online object and never deletes anything. The cutover (disabling the
    organization relationships, sharing policy entries and availability address spaces, coordinated with
    each partner) stays manual: the reports give the commands and their rollback. Microsoft Graph v1.0 only.

.PARAMETER Mode
    Collect (default), Plan or Apply.

.PARAMETER Phase
    Apply: Entra, Exchange or All (required). Plan: which phase to show as "to do" (default All).

.PARAMETER SnapshotPath
    Plan / Apply: folder of a Collect run (or its snapshot.json). Default: the most recent Collect run of
    the tenant in Output.Path.

.PARAMETER SelectionPath
    Plan / Apply: Selection.csv completed by the administrator (Include, Level, Scope). Without it, every
    item proposed by the collection and the configuration rules is migrated.

.PARAMETER Feature
    Plan / Apply: limit this run to some features - FreeBusy, MailTips, CalendarSharing, AnonymousCalendarSharing.
    The other items are not migrated in this run (they stay in the reports). Collect always reads everything.
    Example: -Feature FreeBusy, MailTips while calendar sharing is not yet available in X-TAP for your tenants.
    With pwsh -File (scheduled task), write the list without spaces: -Feature FreeBusy,MailTips

.PARAMETER ConfigPath
    Configuration file. Default: config\XTapSharingMigration.config.psd1 next to this script.

.PARAMETER UserPrincipalName
    Account expected for this run (overrides Authentication.ExchangeAdmin / Authentication.EntraAdmin).

.PARAMETER Force
    Apply: no confirmation prompt (required when the run is not interactive).

.EXAMPLE
    .\Invoke-XTapSharingMigration.ps1
    Inventory (read-only): Inventory.html, Selection.csv, snapshot.json.

.EXAMPLE
    .\Invoke-XTapSharingMigration.ps1 -Mode Plan -SelectionPath .\output\contoso.onmicrosoft.com\2026-10-01_101500_Collect\Selection.csv
    What would be configured for the items chosen in Selection.csv.

.EXAMPLE
    .\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Entra
    Security groups and Microsoft 365 collaboration trusts (Entra administrator).

.EXAMPLE
    .\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Exchange
    Capabilities (Exchange administrator), once the Entra phase is done.

.EXAMPLE
    .\Invoke-XTapSharingMigration.ps1 -Mode Plan -Feature FreeBusy, MailTips
    Plan limited to Free/Busy and MailTips (calendar sharing not yet rolled out): use the same -Feature for Apply.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    Exit codes : 0 = success, 1 = failure, 2 = finished with items to look at (blocked, skipped, not verified).
    Documentation : docs\XTapSharingMigration-Guide.md (or .html)
#>
[CmdletBinding()]
param(
    [ValidateSet('Collect', 'Plan', 'Apply')]
    [string]$Mode = 'Collect',
    [ValidateSet('Entra', 'Exchange', 'All')]
    [string]$Phase,
    [string]$SnapshotPath,
    [string]$SelectionPath,
    [ArgumentCompletions('FreeBusy', 'MailTips', 'CalendarSharing', 'AnonymousCalendarSharing')]
    [string[]]$Feature,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\XTapSharingMigration.config.psd1'),
    [string]$UserPrincipalName,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$clock = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
$exo = $null; $graph = $null

try {
    # do { } while ($false): 'break' ends the execution early; the finally block always runs.
    do {
        Import-Module (Join-Path $PSScriptRoot 'XTapSharingMigration.psd1') -Force
        $settings = Import-XsmConfiguration -Path $ConfigPath -Root $PSScriptRoot
        if ($Mode -eq 'Apply' -and -not $Phase) { throw '-Mode Apply needs -Phase: Entra (groups and trusts), Exchange (capabilities) or All (both).' }
        if (-not $Phase) { $Phase = 'All' }
        $logPath = Start-XsmLog -Directory $settings.Logging.Path -RetentionDays $settings.Logging.RetentionDays
        $dot = [char]0x00B7
        $tenantText = if ($settings.Tenant.Organization) { "$($settings.Tenant.Organization)  ($($settings.Tenant.TenantId))" } else { $settings.Tenant.TenantId }
        $modeText = switch ($Mode) {
            'Collect' { "Collect $dot read-only inventory" }
            'Plan' { "Plan $dot read-only $dot $(if ($Phase -eq 'All') { 'both phases' } else { "phase $Phase" })" }
            'Apply' { "Apply $dot phase $Phase" }
        }
        if ($Feature) {
            # 'FreeBusy,MailTips' in one string too: pwsh -File (scheduled task) does not build an array.
            $known = @('FreeBusy', 'MailTips', 'CalendarSharing', 'AnonymousCalendarSharing')
            $Feature = @($Feature -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $n = $_; $m = $known | Where-Object { $_ -eq $n }; if (-not $m) { throw "-Feature: unknown feature '$n'. Use $($known -join ', ')." }; $m } | Select-Object -Unique)
            if ($Mode -ne 'Collect') { $settings.RunFeatures = $Feature }
        }
        $banner = [ordered]@{ Mode = @('Target', $modeText); Tenant = @('Partner', $tenantText) }
        if ($settings.RunFeatures.Count) { $banner['Features'] = @('Calendar', (($settings.RunFeatures -join ', ') + "  (-Feature: the other features are not migrated in this run)")) }
        $banner['Config'] = @('File', $settings.Path); $banner['Log'] = @('Log', $logPath)
        Write-XsmBanner -Title 'X-TAP Sharing Migration' -Subtitle "Free/Busy $dot MailTips $dot calendar sharing  $([char]0x2192)  Microsoft 365 X-TAP" -Details $banner
        $expectedExchange = if ($UserPrincipalName) { $UserPrincipalName } else { $settings.Authentication.ExchangeAdmin }
        $expectedEntra = if ($UserPrincipalName) { $UserPrincipalName } elseif ($settings.Authentication.EntraAdmin) { $settings.Authentication.EntraAdmin } else { $settings.Authentication.ExchangeAdmin }

        # =====================================================================================================
        # COLLECT
        # =====================================================================================================
        if ($Mode -eq 'Collect') {
            $total = 4
            if ($Feature) { Write-XsmItem Info '-Feature is ignored by Collect: the inventory always reads every feature. Use it with -Mode Plan and -Mode Apply.' }
            # Microsoft Graph first: ExchangeOnlineManagement loads its own Microsoft.IdentityModel assemblies into
            # the session, and the interactive Graph sign-in fails after it ("Method not found ... WithLogging").
            # Every Graph read that needs a sign-in is therefore done before Exchange Online.
            Write-XsmStep 1 $total 'Microsoft Graph: current Microsoft 365 X-TAP (read-only)' -Icon Graph
            $versions = Import-XsmModules -Graph -Exchange -Mode $settings.Authentication.Mode
            Write-XsmLog 'INFO' ("Modules: " + (($versions.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))
            if ($settings.Authentication.Mode -eq 'Interactive') { Write-XsmItem Info 'Two sign-ins may be asked (Microsoft Graph, then Exchange Online): use an administrator of the tenant.' -Icon People }
            try {
                $graph = Connect-XsmGraph -Settings $settings -Scopes (Get-XsmGraphScopes -Mode Collect) -ExpectedAccount $expectedExchange
                Write-XsmItem Ok "$($graph.Account)  $dot tenant verified  $dot Microsoft.Graph.Authentication $($versions['Microsoft.Graph.Authentication'])"
                if ($graph.MissingScopes.Count) { Write-XsmItem Warn "Permissions not granted: $($graph.MissingScopes -join ', ') - some information may be missing." }
                $xtap = Get-XsmXtapState -AllPartners
                if ($xtap.Readable) {
                    $trusted = @($xtap.Partners | Where-Object { $_.Trust.State -ne 'NotConfigured' }).Count
                    Write-XsmItem Ok ("Default policy: {0} capabilit(ies) {1} {2} partner polic(ies), {3} with Microsoft 365 collaboration" -f @($xtap.Default.Capabilities).Count, $dot, @($xtap.Partners).Count, $trusted) -Icon Graph
                } else { Write-XsmItem Warn "Microsoft 365 X-TAP not read: $($xtap.Error)" }
            } catch {
                Write-XsmItem Warn "No Microsoft Graph connection: $($_.Exception.Message)"
                Write-XsmItem Info 'The inventory continues without the current X-TAP state and without the partner names.'
                $graph = $null
                $xtap = [ordered]@{ Readable = $false; Error = 'No Microsoft Graph connection'; Default = $null; Partners = @() }
            }

            Write-XsmStep 2 $total 'Exchange Online: sharing configuration (read-only)' -Icon Exchange
            $exo = Connect-XsmExchange -Settings $settings -ExpectedAccount $expectedExchange
            Write-XsmItem Ok "$($exo.Account)  $dot tenant verified  $dot ExchangeOnlineManagement $($versions['ExchangeOnlineManagement'])"
            $runDir = New-XsmRunDirectory -Settings $settings -Name 'Collect'
            $collectId = (Split-Path $runDir -Leaf) -replace '_Collect$', ''
            $exchange = Get-XsmExchangeInventory -Settings $settings -BackupDirectory (Join-Path $runDir 'backup')
            $inventory = $exchange.Inventory
            if ($exchange.Mailboxes.Count) {
                $text = ($exchange.Mailboxes | Sort-Object SharingPolicy, PrimarySmtpAddress | ConvertTo-Csv -Delimiter ';' -NoTypeInformation -UseQuotes AsNeeded) -join "`r`n"
                [IO.File]::WriteAllText((Join-Path $runDir 'SharingPolicyMailboxes.csv'), $text + "`r`n", [Text.UTF8Encoding]::new($true))
            }
            Disconnect-XsmExchange $exo; $exoAccount = $exo.Account; $exo = $null

            Write-XsmStep 3 $total 'Partner tenants: tenant ID of each external domain' -Icon Partner
            $domains = @(Get-XsmExternalDomains $inventory)
            $own = if ($settings.Tenant.Organization) { $settings.Tenant.Organization } else { @($inventory.AcceptedDomains | Where-Object { $_ -like '*.onmicrosoft.com' -and $_ -notlike '*.mail.onmicrosoft.com' }) | Select-Object -First 1 }
            $ownInfo = if ($own) { Resolve-XsmDomainTenant -Domain $own } else { $null }
            if ($ownInfo -and $ownInfo.TenantId -and $ownInfo.TenantId -ne $settings.Tenant.TenantId) { Write-XsmItem Warn "Tenant.Organization $own belongs to tenant $($ownInfo.TenantId), not to $($settings.Tenant.TenantId)." }
            $resolved = Resolve-XsmDomainTenants -Domains $domains -UseGraph:([bool]$graph)
            $tenantIds = @(@($resolved.Values | Where-Object { $_.Status -eq 'Resolved' -and $_.TenantId -ne $settings.Tenant.TenantId } | ForEach-Object { $_.TenantId }) + @($inventory.AvailabilityAddressSpaces | ForEach-Object { $_.TargetTenantId } | Where-Object { $_ }) | Select-Object -Unique)
            $notFound = @($resolved.Values | Where-Object { $_.Status -ne 'Resolved' })
            Write-XsmItem Ok ("{0} external domain(s) {1} {2} Microsoft Entra tenant(s){3}" -f $domains.Count, [char]0x2192, $tenantIds.Count, $(if ($notFound.Count) { "  $dot $($notFound.Count) without a Microsoft 365 tenant or not resolved" })) -Icon Partner
            if ($graph -and -not (Test-XsmTenantInfoAvailable)) { Write-XsmItem Info 'Partner names not available from Microsoft Graph: domains are shown instead.' }
            $names = @{}
            foreach ($r in $resolved.Values) { if ($r.TenantId -and -not $names.ContainsKey($r.TenantId)) { $names[$r.TenantId] = if ($r.DisplayName) { $r.DisplayName } else { $r.Domain } } }
            foreach ($p in @($xtap.Partners)) { $p['Name'] = if ($names.ContainsKey($p.TenantId)) { $names[$p.TenantId] } else { '' } }

            Write-XsmStep 4 $total 'Classification and output files' -Icon Report
            $snapshot = [ordered]@{
                Tool        = [ordered]@{ Name = 'X-TAP Sharing Migration'; Version = (Get-Module XTapSharingMigration).Version.ToString() }
                CollectId   = $collectId
                CollectedAt = [DateTime]::UtcNow.ToString('o')
                Tenant      = [ordered]@{
                    TenantId = $settings.Tenant.TenantId; Organization = $(if ($own) { $own } else { '' }); DisplayName = [string]$inventory.Organization.DisplayName
                    Cloud = $(if ($ownInfo) { $ownInfo.Cloud } else { '' }); Region = $(if ($ownInfo) { $ownInfo.Region } else { '' })
                }
                Accounts    = [ordered]@{ 'Exchange Online' = $exoAccount; 'Microsoft Graph' = $(if ($graph) { $graph.Account } else { 'not connected' }) }
                Exchange    = $inventory
                Domains     = $resolved
                Xtap        = $xtap
                Items       = @()
                Sources     = @()
            }
            $classification = Get-XsmMigrationItems -Snapshot $snapshot -Settings $settings
            $snapshot.Items = $classification.Items
            $snapshot.Sources = $classification.Sources
            Save-XsmJson $snapshot (Join-Path $runDir 'snapshot.json')
            $selectionFile = Join-Path $runDir 'Selection.csv'
            Export-XsmSelection -Items $snapshot.Items -Settings $settings -Path $selectionFile -CollectId $collectId

            $items = @($snapshot.Items)
            $inScope = @($items | Where-Object Status -eq 'InScope')
            $proposed = @($items | ForEach-Object { Get-XsmItemDecision -Item $_ -Settings $settings } | Where-Object Include)
            $rows = foreach ($i in ($items | Sort-Object @{ Expression = { $_.Status -ne 'InScope' } }, @{ Expression = { $_.ItemId } })) {
                $d = Get-XsmItemDecision -Item $i -Settings $settings
                [pscustomobject]@{
                    Status = $(if ($i.Status -eq 'InScope') { if ($d.Include) { 'Ok' } else { 'Skip' } } else { 'Skip' })
                    Item = $i.ItemId; Feature = $i.Feature; Partner = $(if ($i.PartnerName) { $i.PartnerName } else { $i.Target })
                    Source = $i.SourceName; Found = $i.ExchangeSetting
                    Result = $(if ($i.Status -ne 'InScope') { "out of scope: $($i.Reason)" } elseif (-not $d.Include) { "excluded: $($d.IncludeOrigin)" } else { "$($d.Level) $dot $(Format-XsmScope (ConvertTo-XsmScopeSpec $d.Scope $settings)) $dot $(@{ Present = 'already in X-TAP'; PresentOtherScope = 'in X-TAP, other scope'; OtherLevel = 'other level in X-TAP'; Missing = 'not in X-TAP yet'; Unknown = 'X-TAP not read'; NotApplicable = '' }[[string]$i.XtapStatus])" })
                }
            }
            $shown = @($rows | Select-Object -First 40)
            Write-XsmTable -Columns @(@{ Name = 'Item'; Property = 'Item'; Width = 9 }, @{ Name = 'Feature'; Property = 'Feature'; Width = 15 }, @{ Name = 'Partner'; Property = 'Partner'; Width = 24 }, @{ Name = 'Exchange source'; Property = 'Source'; Width = 26 }, @{ Name = 'Proposal'; Property = 'Result'; Width = 0 }) -Rows $shown
            if (@($rows).Count -gt $shown.Count) { Write-XsmItem Info "... $(@($rows).Count - $shown.Count) more item(s): see Inventory.html or Selection.csv." }
            $reasons = @($items | Where-Object Status -ne 'InScope' | Group-Object { $_.Reason } | ForEach-Object { "$($_.Name) $($_.Count)" })

            # Partner tenant IDs: found from the domains, to be confirmed by each partner before the Entra phase.
            $partners = @(Get-XsmPartnerSummary -Snapshot $snapshot -Settings $settings)
            $snapshot['Partners'] = $partners
            Save-XsmJson $snapshot (Join-Path $runDir 'snapshot.json')
            if ($partners.Count) {
                Write-XsmSection 'Partner tenants in scope - tenant ID to confirm with each partner' -Icon Partner
                $prow = foreach ($p in $partners) {
                    [pscustomobject]@{
                        Status = @{ Confirmed = 'Ok'; Mismatch = 'Fail'; NotConfirmed = 'Warn' }[$p.Confirmation]
                        Name = $p.Name; TenantId = $p.TenantId; Domains = (@($p.Domains) -join ', ')
                        State = $(if ($p.PartnerSideOnly) { "partner configures its side (address space)$(if ($p.Confirmation -eq 'Confirmed') { '' } else { ' - ID to confirm' })" } else { @{ Confirmed = "confirmed: $($p.ConfirmationSource)"; Mismatch = 'MISMATCH with the Partners rule'; NotConfirmed = 'to confirm' }[$p.Confirmation] })
                    }
                }
                Write-XsmTable -Columns @(@{ Name = 'Partner'; Property = 'Name'; Width = 24 }, @{ Name = 'Tenant ID found'; Property = 'TenantId'; Width = 36 }, @{ Name = 'Domains'; Property = 'Domains'; Width = 30 }, @{ Name = 'Confirmation'; Property = 'State'; Width = 0 }) -Rows @($prow)
                Export-XsmPartnerSnippet -Partners $partners -Path (Join-Path $runDir 'PartnersToConfirm.txt') -Settings $settings
            }
            $toConfirm = @($partners | Where-Object { $_.Confirmation -ne 'Confirmed' -and -not $_.PartnerSideOnly }).Count

            # Same partner, same feature, several levels in Exchange Online: the administrator chooses (asked by Plan / Apply).
            $proposalEntries = @($items | ForEach-Object { [ordered]@{ Item = $_; Decision = (Get-XsmItemDecision -Item $_ -Settings $settings) } })
            $conflicts = @(Get-XsmLevelConflicts -Entries $proposalEntries -Settings $settings)
            if ($conflicts.Count) {
                Write-XsmSection 'Choices to make - several levels for the same partner and feature' -Icon Question
                $crow = foreach ($c in $conflicts) {
                    [pscustomobject]@{ Status = 'Warn'; Partner = $c.PartnerName; Feature = $c.Feature; Found = (@($c.Options | ForEach-Object { "$($_.Level) ($(@($_.Sources) -join ', '))" }) -join '  /  ') }
                }
                Write-XsmTable -Columns @(@{ Name = 'Partner'; Property = 'Partner'; Width = 26 }, @{ Name = 'Feature'; Property = 'Feature'; Width = 15 }, @{ Name = 'Levels found'; Property = 'Found'; Width = 0 }) -Rows @($crow)
                Write-XsmItem Info 'Plan and Apply ask which level to keep (answers recorded in LevelChoices.json); or set it in Selection.csv or a Partners rule.'
            }

            $data = New-XsmReportData -Kind Collect -Settings $settings -Snapshot $snapshot
            $data.Accounts = $snapshot.Accounts
            $data.Items = ConvertTo-XsmReportItems -Items $items -Settings $settings
            $data.Sources = $snapshot.Sources; $data.Exchange = $inventory; $data.Xtap = $xtap; $data.Partners = $partners; $data.Conflicts = $conflicts
            $partnerCount = @($inScope | Where-Object { $_.Target -eq 'Partner' -and $_.PartnerTenantId } | ForEach-Object PartnerTenantId | Select-Object -Unique).Count
            $present = @($inScope | Where-Object XtapStatus -eq 'Present').Count
            $data.Metrics = @(
                @{ Label = 'Items proposed'; Value = $proposed.Count; Hint = "of $($items.Count) item(s) found in Exchange Online" }
                @{ Label = 'Partner tenants'; Value = $partnerCount; Hint = 'external Microsoft 365 organizations in scope' }
                @{ Label = 'Out of scope'; Value = ($items.Count - $inScope.Count); Hint = $(if ($reasons.Count) { $reasons -join ' · ' } else { 'nothing excluded' }) }
                @{ Label = 'Already in X-TAP'; Value = $(if ($xtap.Readable) { $present } else { '?' }); Hint = $(if ($xtap.Readable) { 'items already configured with the same level and scope' } else { 'X-TAP not read' }) }
            )
            $data.Warnings = @($inventory.Errors) + @(if (-not $xtap.Readable) { "Microsoft 365 X-TAP not read: $($xtap.Error)" }) + @($conflicts | ForEach-Object { "Choice needed - $($_.PartnerName), $($_.Feature): $(@($_.Options | ForEach-Object { "$($_.Level) ($(@($_.Sources) -join ', '))" }) -join ' / '). Plan and Apply will ask which level to keep." })
            $report = Join-Path $runDir 'Inventory.html'
            New-XsmHtmlReport -Data $data -Path $report
            Write-XsmItem Ok 'Inventory.html  (initial picture of the configuration)' -Icon File
            Write-XsmItem Ok 'Selection.csv   (Include / Level / Scope, to complete if you choose item by item)' -Icon File
            Write-XsmItem Ok 'snapshot.json   (input of -Mode Plan and -Mode Apply)' -Icon File
            if ($partners.Count) { Write-XsmItem Ok 'PartnersToConfirm.txt  (Partners entries to paste in the configuration once each partner has confirmed its tenant ID)' -Icon File }
            if ($settings.Collection.BackupExchangeObjects) { Write-XsmItem Ok 'backup\         (organization relationships, sharing policies, address spaces: Export-Clixml)' -Icon Folder }

            Write-XsmSummary -Title 'Inventory ready' -Status $(if ($inventory.Errors.Count -or -not $xtap.Readable) { 'Warn' } else { 'Ok' }) -Values ([ordered]@{
                    Items    = @('Target', "$($proposed.Count) proposed for migration $dot $($items.Count - $inScope.Count) out of scope$(if ($reasons.Count) { " ($($reasons -join ', '))" })")
                    Partners = @('Partner', "$partnerCount Microsoft 365 tenant(s) in scope$(if ($toConfirm) { " $dot $toConfirm tenant ID(s) to confirm with the partner (PartnersToConfirm.txt)" })")
                    Choices  = @($(if ($conflicts.Count) { 'Question' } else { 'Ok' }), $(if ($conflicts.Count) { "$($conflicts.Count) level choice(s) to make (asked by Plan / Apply)" } else { 'no level to choose' }))
                    'X-TAP'  = @('Graph', $(if ($xtap.Readable) { "$present item(s) already in place" } else { 'not read' }))
                    Report   = @('Report', $report)
                    Next     = @('Plan', '.\Invoke-XTapSharingMigration.ps1 -Mode Plan   (add -SelectionPath for an item-by-item choice)')
                    Duration = @('Clock', (Format-XsmDuration $clock.Elapsed.TotalSeconds))
                })
            $exitCode = if ($inventory.Errors.Count -or -not $xtap.Readable) { 2 } else { 0 }
            break
        }

        # =====================================================================================================
        # PLAN / APPLY
        # =====================================================================================================
        $total = if ($Mode -eq 'Plan') { 4 } else { 6 }
        Write-XsmStep 1 $total 'Loading the snapshot and the selection' -Icon Snapshot
        if (-not $SnapshotPath) {
            $SnapshotPath = Find-XsmLatestSnapshot -Settings $settings
            if (-not $SnapshotPath) { throw "No Collect run found for this tenant in $($settings.Output.Path). Run -Mode Collect first, or give -SnapshotPath." }
        }
        $snapshot = Import-XsmSnapshot -Path $SnapshotPath -Settings $settings
        $age = [DateTime]::UtcNow - [DateTime]::Parse([string]$snapshot.CollectedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Write-XsmItem Ok ("Snapshot {0}  {1} {2} item(s)  {1} collected {3} ago" -f $snapshot.CollectId, $dot, @($snapshot.Items).Count, (Format-XsmDuration $age.TotalSeconds)) -Icon Snapshot
        if ($age.TotalDays -gt 7) { Write-XsmItem Warn 'The snapshot is more than 7 days old: run -Mode Collect again for an up-to-date picture.' }
        $selection = $null
        if ($SelectionPath) {
            $SelectionPath = [IO.Path]::GetFullPath($SelectionPath, (Get-Location).Path)
            $selection = Import-XsmSelection -Path $SelectionPath -Snapshot $snapshot
            if ($selection.Errors.Count) { throw ("Selection.csv cannot be used ($SelectionPath):`n - " + ($selection.Errors -join "`n - ")) }
            Write-XsmItem Ok ("Selection {0}  {1} {2} row(s), {3} with Include = Yes" -f (Split-Path $SelectionPath -Leaf), $dot, $selection.Rows.Count, @($selection.Rows.Values | Where-Object Include).Count) -Icon File
        } else {
            Write-XsmItem Info 'No -SelectionPath: every item proposed by the collection and the configuration rules is migrated.'
        }

        Write-XsmStep 2 $total 'Building the target configuration' -Icon Target
        $mailboxes = Import-XsmSharingPolicyMailboxes -Snapshot $snapshot
        $levelChoices = Import-XsmLevelChoices -Snapshot $snapshot
        $target = New-XsmTargetState -Snapshot $snapshot -Settings $settings -Selection $selection -MailboxesByPolicy $mailboxes -LevelChoices $levelChoices
        foreach ($c in @($target.Conflicts | Where-Object Chosen)) { Write-XsmItem Ok ("{0} - {1}: {2} (chosen by {3})" -f $c.PartnerName, $c.Feature, $c.Chosen, $(if ($levelChoices[$c.Key]['By']) { $levelChoices[$c.Key]['By'] } else { 'LevelChoices.json' })) -Icon Question }
        $open = @($target.Conflicts | Where-Object { -not $_.Chosen })
        if ($open.Count) {
            if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
                foreach ($c in $open) { Write-XsmItem Warn ("{0} - {1}: several levels found ({2}). Not interactive: these items stay blocked until a level is chosen." -f $c.PartnerName, $c.Feature, (@($c.Options | ForEach-Object { $_.Level }) -join ' / ')) }
            } elseif (Request-XsmLevelChoices -Conflicts $open -Choices $levelChoices -Account $(if ($UserPrincipalName) { $UserPrincipalName } elseif ($expectedExchange) { $expectedExchange } else { [Environment]::UserName })) {
                Save-XsmLevelChoices -Snapshot $snapshot -Choices $levelChoices
                $target = New-XsmTargetState -Snapshot $snapshot -Settings $settings -Selection $selection -MailboxesByPolicy $mailboxes -LevelChoices $levelChoices
            }
        }
        $migrated = @($target.Decisions | Where-Object { $_.Decision.Include -and -not $_.Decision.Problems.Count })
        $problems = @($target.Decisions | Where-Object { $_.Decision.Include -and $_.Decision.Problems.Count })
        Write-XsmItem Ok ("{0} item(s) migrated of {1}  {2} {3} capabilit(ies), {4} partner(s), {5} security group(s)" -f $migrated.Count, @($target.Decisions).Count, $dot, @($target.Capabilities).Count, @($target.Trusts).Count, @($target.Groups).Count) -Icon Target
        if ($settings.RunFeatures.Count) {
            $left = @($target.Decisions | Where-Object { $_.Item.Status -eq 'InScope' -and "$($_.Decision.IncludeOrigin)" -like '-Feature*' })
            if ($left.Count) { Write-XsmItem Info ("{0} item(s) in scope left for a later run (-Feature): {1}" -f $left.Count, ((@($left | Group-Object { $_.Item.Feature } | ForEach-Object { "$($_.Name) $($_.Count)" })) -join ', ')) }
        }
        foreach ($p in $problems) { Write-XsmItem Fail ("{0}: {1}" -f $p.Item.ItemId, ($p.Decision.Problems -join ' ')) }
        foreach ($w in @($target.Decisions | Where-Object { $_.Decision.Include } | ForEach-Object { foreach ($x in $_.Decision.Warnings) { "$($_.Item.ItemId): $x" } })) { Write-XsmItem Warn $w }
        foreach ($w in $target.Warnings) { Write-XsmItem Warn $w }

        Write-XsmStep 3 $total 'Connecting to Microsoft Graph and comparing with the tenant' -Icon Graph
        $null = Import-XsmModules -Graph -Mode $settings.Authentication.Mode
        $createsGroups = [bool]@($target.Groups | Where-Object Create).Count
        $scopes = Get-XsmGraphScopes -Mode $Mode -Phase $Phase -Groups:$createsGroups
        $account = if ($Mode -eq 'Apply' -and $Phase -in 'Entra', 'All') { $expectedEntra } else { $expectedExchange }
        if ($settings.Authentication.Mode -eq 'Interactive') { Write-XsmItem Info ("A sign-in window may open: sign in with {0}." -f $(if ($Mode -eq 'Apply') { @{ Entra = 'a Security Administrator / Groups Administrator (or Global Administrator)'; Exchange = 'an Exchange Administrator (or Global Administrator)'; All = 'a Global Administrator' }[$Phase] } else { 'an administrator of the tenant (read-only use)' })) -Icon People }
        $graph = Connect-XsmGraph -Settings $settings -Scopes $scopes -ExpectedAccount $account
        Write-XsmItem Ok "$($graph.Account)  $dot tenant verified  $dot $($scopes -join ', ')"
        if ($graph.MissingScopes.Count) { Write-XsmItem Warn "Permissions not granted: $($graph.MissingScopes -join ', ')." }
        $live = Get-XsmLiveState -Target $target -Members:($Phase -in 'Entra', 'All')
        $actions = New-XsmActions -Target $target -Live $live -Settings $settings -Phase $Phase
        Show-XsmActions -Actions $actions -Phase $Phase
        $counts = Get-XsmActionCounts $actions

        $runDir = New-XsmRunDirectory -Settings $settings -Name $(if ($Mode -eq 'Plan') { 'Plan' } else { "Apply-$Phase" })
        $cutover = Get-XsmCutover -Snapshot $snapshot -Target $target
        $applied = $false
        if ($Mode -eq 'Apply') {
            Write-XsmStep 4 $total 'Confirmation' -Icon Lock
            $todo = @($actions | Where-Object Status -eq 'ToDo')
            if (-not $todo.Count) {
                Write-XsmItem Ok "Nothing to change in phase $Phase."
            } else {
                $question = "Apply the $($todo.Count) change(s) of phase $Phase to tenant $($settings.Tenant.Organization) $($settings.Tenant.TenantId)?"
                if (-not $Force) {
                    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { throw "$question Not interactive: add -Force to confirm." }
                    Write-Host ''
                    $answer = Read-Host "      $question Type YES to continue"
                    Write-XsmLog 'INFO' "Confirmation answer: $answer"
                    if ($answer -cne 'YES') { Write-XsmItem Skip 'Cancelled: nothing was changed.'; $todo = @(); foreach ($a in $actions) { if ($a.Status -eq 'ToDo') { $a.Status = 'Skipped'; $a.Error = 'Cancelled at the confirmation.' } } }
                } else { Write-XsmItem Info "-Force: $($todo.Count) change(s) confirmed." }
            }
            Write-XsmStep 5 $total "Applying phase $Phase" -Icon Apply
            if ($todo.Count) {
                $groupIds = Invoke-XsmActions -Actions $actions -Live $live
                $applied = $true
            } else { Write-XsmItem Skip 'No change made.' }

            Write-XsmStep 6 $total 'Verification and report' -Icon Report
            if ($applied) {
                $after = New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target -Members:($Phase -in 'Entra', 'All') -KnownGroupIds $groupIds) -Settings $settings -Phase $Phase
                Set-XsmVerification -Actions $actions -After $after
                foreach ($a in @($actions | Where-Object Status -eq 'Done')) {
                    $status = if ($a.Verified -like 'Verified*') { 'Ok' } else { 'Warn' }
                    Write-XsmItem $status ("{0}  {1}" -f $a.Id, $a.Verified) -Indent 8
                }
            }
            $counts = Get-XsmActionCounts $actions
        } else {
            Write-XsmStep 4 $total 'Writing the plan' -Icon Report
        }

        $kind = if ($Mode -eq 'Plan') { 'Plan' } else { 'Apply' }
        $data = New-XsmReportData -Kind $kind -Settings $settings -Snapshot $snapshot -Phase $Phase
        $data.Accounts = [ordered]@{ 'Microsoft Graph' = $graph.Account }
        $data.SnapshotPath = [string]$snapshot.Directory
        $data.SelectionPath = $(if ($SelectionPath) { $SelectionPath } else { '' })
        $data.Items = ConvertTo-XsmReportItems -Items @($snapshot.Items) -Settings $settings -Decisions $target.Decisions
        $data.Actions = @($actions | ForEach-Object { ConvertTo-XsmReportAction $_ })
        $data.Target = ConvertTo-XsmReportTarget $target
        $data.Cutover = $cutover
        $data.Exchange = $snapshot.Exchange; $data.Sources = $snapshot.Sources
        $data.Xtap = ConvertTo-XsmReportXtap -Live $live -Target $target
        $data.Warnings = @($target.Warnings) + @($problems | ForEach-Object { "$($_.Item.ItemId): $($_.Decision.Problems -join ' ')" }) + @($actions | Where-Object { $_.Operation -in 'Blocked', 'Conflict' } | ForEach-Object { "$($_.Id) $($_.Target): $($_.Detail)" })
        $data.Errors = @($actions | Where-Object Status -eq 'Failed' | ForEach-Object { "$($_.Id) $($_.Operation) $($_.Kind) $($_.Target): $($_.Error)" })
        if ($kind -eq 'Plan') {
            $data.Metrics = @(
                @{ Label = 'Entra changes'; Value = $counts.EntraToDo; Hint = 'security groups and Microsoft 365 collaboration trusts' }
                @{ Label = 'Exchange changes'; Value = $counts.ExchangeToDo; Hint = 'Free/Busy, MailTips and calendar sharing capabilities' }
                @{ Label = 'Already in place'; Value = $counts.NoChange; Hint = 'nothing to change' }
                @{ Label = 'Blocked'; Value = ($counts.Blocked + $problems.Count); Hint = 'actions blocked or items that cannot be migrated' }
            )
        } else {
            $data.Metrics = @(
                @{ Label = 'Changes done'; Value = $counts.Done; Hint = "phase $Phase, verified: $(@($actions | Where-Object { $_.Verified -like 'Verified*' }).Count)" }
                @{ Label = 'Already in place'; Value = $counts.NoChange; Hint = 'nothing to change' }
                @{ Label = 'Other phase'; Value = @($actions | Where-Object Status -eq 'OtherPhase').Count; Hint = 'to be done by the other administrator' }
                @{ Label = 'Failed / blocked'; Value = ($counts.Failed + $counts.Skipped + $counts.Blocked); Hint = 'see the Actions tab' }
            )
        }
        $baseName = if ($kind -eq 'Plan') { 'Plan' } else { 'Result' }
        $report = Join-Path $runDir "$baseName.html"
        New-XsmHtmlReport -Data $data -Path $report
        Export-XsmActionsCsv -Actions $actions -Path (Join-Path $runDir "$baseName.csv") -Settings $settings
        Export-XsmCutoverText -Cutover $cutover -Path (Join-Path $runDir 'ManualCutover.txt') -Settings $settings
        Save-XsmJson ([ordered]@{ Kind = $kind; Phase = $Phase; Snapshot = $snapshot.Directory; Selection = $SelectionPath; Actions = $data.Actions; Target = $data.Target; Cutover = $cutover }) (Join-Path $runDir "$($baseName.ToLowerInvariant()).json")
        Write-XsmItem Ok "$baseName.html  $dot $baseName.csv  $dot ManualCutover.txt" -Icon File

        $notVerified = @($actions | Where-Object { $_.Status -eq 'Done' -and $_.Verified -notlike 'Verified*' }).Count
        $attention = $counts.Blocked + $problems.Count + $counts.Skipped + $notVerified
        if ($kind -eq 'Plan') {
            Write-XsmSummary -Title 'Plan ready - nothing was changed' -Status $(if ($attention) { 'Warn' } else { 'Ok' }) -Values ([ordered]@{
                    Entra     = @('Key', "$($counts.EntraToDo) change(s): security groups, Microsoft 365 collaboration trusts")
                    Exchange  = @('Exchange', "$($counts.ExchangeToDo) change(s): capabilities")
                    'In place' = @('Ok', "$($counts.NoChange) action(s) already in place")
                    Blocked   = @($(if ($attention) { 'Warn' } else { 'Ok' }), "$($counts.Blocked) action(s) blocked, $($problems.Count) item(s) that cannot be migrated")
                    Features  = @('Calendar', $(if ($settings.RunFeatures.Count) { ($settings.RunFeatures -join ', ') + ' only (-Feature)' } else { 'all the features allowed by the configuration' }))
                    Report    = @('Report', $report)
                    Next      = @('Apply', '-Mode Apply -Phase Entra, then -Mode Apply -Phase Exchange (or -Phase All)')
                    Duration  = @('Clock', (Format-XsmDuration $clock.Elapsed.TotalSeconds))
                })
            $exitCode = if ($attention) { 2 } else { 0 }
        } else {
            $other = @($actions | Where-Object Status -eq 'OtherPhase').Count
            $status = if ($counts.Failed) { 'Fail' } elseif ($attention) { 'Warn' } else { 'Ok' }
            Write-XsmSummary -Title $(switch ($status) { 'Ok' { "Phase $Phase applied" } 'Warn' { "Phase $Phase applied - with items to look at" } default { "Phase $Phase finished with errors" } }) -Status $status -Values ([ordered]@{
                    Done      = @('Ok', "$($counts.Done) change(s), $(@($actions | Where-Object { $_.Verified -like 'Verified*' }).Count) verified")
                    'In place' = @('Same', "$($counts.NoChange) action(s) already in place")
                    Problems  = @($(if ($counts.Failed) { 'Fail' } elseif ($attention) { 'Warn' } else { 'Ok' }), "$($counts.Failed) failed $dot $($counts.Skipped) skipped $dot $($counts.Blocked) blocked $dot $notVerified not verified")
                    Other     = @('People', $(if ($other) { "$other action(s) for the other phase ($(if ($Phase -eq 'Entra') { 'Exchange' } else { 'Entra' }))" } else { 'nothing left for another phase' }))
                    Features  = @('Calendar', $(if ($settings.RunFeatures.Count) { ($settings.RunFeatures -join ', ') + ' only (-Feature)' } else { 'all the features allowed by the configuration' }))
                    Cutover   = @('Warn', 'manual and coordinated with each partner: see ManualCutover.txt')
                    Report    = @('Report', $report)
                    Duration  = @('Clock', (Format-XsmDuration $clock.Elapsed.TotalSeconds))
                })
            $exitCode = if ($counts.Failed) { 1 } elseif ($attention) { 2 } else { 0 }
        }
    } while ($false)
}
catch {
    $message = $_.Exception.Message
    Write-Host ''
    if (Get-Command Write-XsmSummary -ErrorAction SilentlyContinue) {
        Write-XsmSummary -Title 'Execution stopped' -Values ([ordered]@{ Error = @('Fail', $message); Duration = @('Clock', (Format-XsmDuration $clock.Elapsed.TotalSeconds)) }) -Status Fail
    } else {
        Write-Host "  [ERROR] $message"
    }
    if (Get-Command Write-XsmLog -ErrorAction SilentlyContinue) { Write-XsmLog -Level 'ERROR' -Message ($message + "`n" + $_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    if (Get-Command Disconnect-XsmExchange -ErrorAction SilentlyContinue) { Disconnect-XsmExchange $exo }
    if (Get-Command Disconnect-XsmGraph -ErrorAction SilentlyContinue) { Disconnect-XsmGraph $graph }
    if (Get-Command Write-XsmLog -ErrorAction SilentlyContinue) {
        Write-XsmLog -Level 'INFO' -Message ("Exit code {0} after {1:0.0} s" -f $exitCode, $clock.Elapsed.TotalSeconds)
        Stop-XsmLog
    }
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
}
exit $exitCode
