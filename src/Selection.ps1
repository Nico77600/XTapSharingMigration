<#
    X-TAP Sharing Migration - decisions and Selection.csv.

    For each item, the decision says whether it is migrated, at which level and with which scope:

        Selection.csv (when -SelectionPath is given)    the administrator's choice, row by row
          > Partners rule of the configuration          for one partner tenant (Match = tenant ID or domain)
          > Features rule of the configuration          for every partner (Level / Scope other than AsDiscovered)
          > what was found in Exchange Online           level and scope of the organization relationship or sharing policy

    Selection.csv is written by -Mode Collect with Include pre-filled (Yes for the items in scope) and the
    Level and Scope columns empty (= the proposal of the configuration). Rows deleted from the file are not
    migrated.
#>

$script:SelectionColumns = @(
    'ItemId', 'Include', 'Level', 'Scope', 'Feature', 'Target', 'PartnerName', 'PartnerTenantId', 'PartnerDomains',
    'Source', 'SourceName', 'ExchangeSetting', 'ProposedLevel', 'ProposedScope', 'Assessment', 'Reason', 'XtapToday', 'Notes', 'CollectId'
)

function Find-XsmPartnerRule {
    <# Partners entry of the configuration that matches an item (its tenant ID, or one of its domains); $null otherwise. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings)
    if ($Item.Target -ne 'Partner') { return $null }
    $tid = ([string]$Item.PartnerTenantId).ToLowerInvariant()
    foreach ($rule in $Settings.Partners) {
        if ($tid -and ($rule.TenantId -eq $tid -or $rule.Match -eq $tid)) { return $rule }
        if (@($Item.PartnerDomains | Where-Object { ([string]$_).ToLowerInvariant() -eq $rule.Match }).Count) { return $rule }
    }
    return $null
}

function Get-XsmPartnerConfirmation {
    <#
    .SYNOPSIS
        Is the tenant ID found for a partner confirmed? The tenant ID is found from the partner's domains
        (OpenID configuration of Microsoft Entra). Before trusting it, it is compared with an independent
        source:
          - Partners rule with TenantId (the value given by the partner's administrator)   -> Confirmed / Mismatch
          - TargetTenantId of an availability address space (typed by an administrator)    -> Confirmed
          - an existing partner policy in Microsoft Entra for this tenant ID (Plan / Apply)  -> Confirmed
        State: Confirmed | Mismatch | NotConfirmed.
    #>
    param([Parameter(Mandatory)][string]$TenantId, [string[]]$Domains = @(), [Parameter(Mandatory)]$Settings, [string[]]$AddressSpaceTenantIds = @(), [switch]$PartnerPolicyExists)
    $tid = $TenantId.ToLowerInvariant()
    $doms = @($Domains | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($rule in $Settings.Partners) {
        if (-not $rule.TenantId) { continue }
        if ($rule.TenantId -eq $tid) { return @{ State = 'Confirmed'; Source = "Partners rule '$(if ($rule.Name) { $rule.Name } else { $rule.Match })'"; Detail = '' } }
        if ($rule.Match -and $rule.Match -in $doms) {
            return @{ State = 'Mismatch'; Source = "Partners rule '$($rule.Match)'"; Detail = "The partner confirmed tenant ID $($rule.TenantId), but $($rule.Match) belongs to tenant $tid in Microsoft Entra. Check with the partner before going further." }
        }
    }
    if ($tid -in @($AddressSpaceTenantIds | ForEach-Object { ([string]$_).ToLowerInvariant() })) { return @{ State = 'Confirmed'; Source = 'TargetTenantId of the availability address space'; Detail = '' } }
    if ($PartnerPolicyExists) { return @{ State = 'Confirmed'; Source = 'existing partner policy in Microsoft Entra'; Detail = '' } }
    return @{ State = 'NotConfirmed'; Source = ''; Detail = "Tenant ID $tid found from the domain(s) $($doms -join ', ') - not confirmed by the partner." }
}

function Get-XsmItemDecision {
    <#
    .SYNOPSIS
        Include / level / scope of one item, with the origin of each value and the problems found.
    .PARAMETER Row
        Row of Selection.csv for this item (hashtable Include, Level, Scope), or $null.
    .PARAMETER UseSelection
        A selection file is used: an item without a row is not migrated.
    #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings, $Row, [switch]$UseSelection)
    $feature = $Item.Feature
    $featureRule = $Settings.Features[$feature]
    $partnerRule = Find-XsmPartnerRule $Item $Settings
    $partnerFeature = if ($partnerRule -and $partnerRule.Features.ContainsKey($feature)) { $partnerRule.Features[$feature] } else { @{} }
    $d = [ordered]@{ ItemId = $Item.ItemId; Include = $false; IncludeOrigin = ''; Level = ''; LevelOrigin = ''; Scope = ''; ScopeOrigin = ''; Problems = [Collections.Generic.List[string]]::new(); Warnings = [Collections.Generic.List[string]]::new() }

    # Include ---------------------------------------------------------------------------------------
    $runFeatures = @($Settings.PSObject.Properties['RunFeatures'] | ForEach-Object { $_.Value } | Where-Object { $_ })
    if ($runFeatures.Count -and $feature -notin $runFeatures) { $d.Include = $false; $d.IncludeOrigin = "-Feature: not in this run ($($runFeatures -join ', '))" }
    elseif ($UseSelection) {
        if ($Row) { $d.Include = [bool]$Row.Include; $d.IncludeOrigin = 'Selection.csv' }
        else { $d.Include = $false; $d.IncludeOrigin = 'Selection.csv (row absent)' }
    } elseif ($Item.Status -ne 'InScope') { $d.Include = $false; $d.IncludeOrigin = "Out of scope: $($Item.ReasonText)" }
    elseif ($partnerRule -and $partnerRule.Include -eq $false) { $d.Include = $false; $d.IncludeOrigin = "Partners rule '$($partnerRule.Match)'" }
    elseif ($partnerFeature.ContainsKey('Migrate')) { $d.Include = [bool]$partnerFeature.Migrate; $d.IncludeOrigin = "Partners rule '$($partnerRule.Match)'" }
    elseif (-not $featureRule.Migrate) { $d.Include = $false; $d.IncludeOrigin = "Features.$feature.Migrate = `$false" }
    else { $d.Include = $true; $d.IncludeOrigin = 'In scope' }

    if ($d.Include -and $Item.Status -ne 'InScope') {
        if ($Item.Overridable) { $d.Warnings.Add("Migrated although out of scope ($($Item.ReasonText)): forced in Selection.csv.") }
        else { $d.Problems.Add("Cannot be migrated: $($Item.ReasonText).") }
    }

    # Level -------------------------------------------------------------------------------------------
    $rowLevel = if ($Row) { [string]$Row.Level } else { '' }
    if ($rowLevel.Trim()) {
        $canonical = Resolve-XsmLevelName $feature $rowLevel
        if ($canonical) { $d.Level = $canonical; $d.LevelOrigin = 'Selection.csv' }
        else { $d.Problems.Add("Level '$rowLevel' is not valid for $feature (valid: $(@($script:FeatureCatalog[$feature].Levels.Keys) -join ', ')).") }
    }
    if (-not $d.Level -and $partnerFeature.ContainsKey('Level')) { $d.Level = $partnerFeature.Level; $d.LevelOrigin = "Partners rule '$($partnerRule.Match)'" }
    if (-not $d.Level -and $featureRule.Level -ne 'AsDiscovered') { $d.Level = $featureRule.Level; $d.LevelOrigin = "Features.$feature.Level" }
    if (-not $d.Level -and $Item.DiscoveredLevel) { $d.Level = $Item.DiscoveredLevel; $d.LevelOrigin = 'Exchange Online' }
    if ($d.Include -and -not $d.Level -and -not $d.Problems.Count) { $d.Problems.Add('No level: set the Level column of Selection.csv.') }

    # Scope -------------------------------------------------------------------------------------------
    $rowScope = if ($Row) { [string]$Row.Scope } else { '' }
    if ($rowScope.Trim()) { $d.Scope = $rowScope.Trim(); $d.ScopeOrigin = 'Selection.csv' }
    elseif ($partnerFeature.ContainsKey('Scope')) { $d.Scope = $partnerFeature.Scope; $d.ScopeOrigin = "Partners rule '$($partnerRule.Match)'" }
    elseif ($featureRule.Scope -ne 'AsDiscovered') { $d.Scope = $featureRule.Scope; $d.ScopeOrigin = "Features.$feature.Scope" }
    else { $d.Scope = [string]$Item.DiscoveredScope; $d.ScopeOrigin = 'Exchange Online' }
    if ($d.Include) {
        foreach ($spec in (ConvertTo-XsmScopeSpec $d.Scope $Settings)) { if ($spec.Kind -eq 'Invalid') { $d.Problems.Add($spec.Message) } }
    }
    $d.Problems = @($d.Problems); $d.Warnings = @($d.Warnings)
    return $d
}

function Export-XsmSelection {
    <# Writes Selection.csv: one row per item, Include pre-filled, Level and Scope empty (= proposal). #>
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CollectId)
    $entries = @($Items | ForEach-Object { [ordered]@{ Item = $_; Decision = (Get-XsmItemDecision -Item $_ -Settings $Settings) } })
    $conflictNote = @{}
    foreach ($c in @(Get-XsmLevelConflicts -Entries $entries -Settings $Settings)) {
        foreach ($id in $c.ItemIds) { $conflictNote[$id] = "LEVEL TO CHOOSE for this partner: $(@($c.Options | ForEach-Object { "$($_.Level) ($(@($_.Sources) -join ', '))" }) -join ' / ') - set the same Level on these rows, or answer the question of Plan / Apply." }
    }
    $rows = foreach ($entry in $entries) {
        $item = $entry.Item; $d = $entry.Decision
        [pscustomobject][ordered]@{
            ItemId          = $item.ItemId
            Include         = $(if ($d.Include) { 'Yes' } else { 'No' })
            Level           = ''
            Scope           = ''
            Feature         = $item.Feature
            Target          = $item.Target
            PartnerName     = $item.PartnerName
            PartnerTenantId = $item.PartnerTenantId
            PartnerDomains  = (@($item.PartnerDomains) -join ' ')
            Source          = $item.Source
            SourceName      = $item.SourceName
            ExchangeSetting = $item.ExchangeSetting
            ProposedLevel   = $d.Level
            ProposedScope   = $d.Scope
            Assessment      = $item.Status
            Reason          = $(if ($item.Status -eq 'InScope') { '' } else { "$($item.Reason) - $($item.ReasonText)$(if ($item.Overridable) { ' (can be forced)' })" })
            XtapToday       = $item.XtapStatus
            Notes           = (@(@($conflictNote[[string]$item.ItemId]) + @($item.Notes) | Where-Object { $_ }) -join ' | ')
            CollectId       = $CollectId
        }
    }
    # UTF-8 with BOM: Excel opens accents correctly.
    $text = ($rows | ConvertTo-Csv -Delimiter $Settings.Output.CsvDelimiter -NoTypeInformation -UseQuotes AsNeeded) -join "`r`n"
    [IO.File]::WriteAllText($Path, $text + "`r`n", [Text.UTF8Encoding]::new($true))
}

function ConvertTo-XsmBoolean {
    param([AllowEmptyString()][string]$Value)
    switch -Regex ($Value.Trim()) {
        '^(?i)(yes|y|true|1|oui|o|x)$' { return $true }
        '^(?i)(no|n|false|0|non|)$' { return $false }
        default { return $null }
    }
}

function Import-XsmSelection {
    <#
    .SYNOPSIS
        Reads Selection.csv completed by the administrator. Returns @{ Rows = ItemId -> @{ Include; Level; Scope }; Errors }.
        The delimiter is detected (';' or ','), so a file saved again by Excel with other regional settings is read.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Snapshot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Selection file not found: $Path" }
    $lines = [IO.File]::ReadAllLines($Path)
    $header = @($lines | Where-Object { $_.Trim() } | Select-Object -First 1)[0]
    if (-not $header) { throw "The selection file is empty: $Path" }
    $delimiter = if (($header.Split(';').Count) -ge ($header.Split(',').Count)) { ';' } else { ',' }
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delimiter -Encoding UTF8)
    $errors = [Collections.Generic.List[string]]::new()
    $names = if ($rows.Count) { @($rows[0].PSObject.Properties.Name) } else { @($header.Split($delimiter) | ForEach-Object { $_.Trim('"') }) }
    foreach ($required in 'ItemId', 'Include', 'Level', 'Scope') { if ($required -notin $names) { $errors.Add("Column '$required' is missing.") } }
    if ($errors.Count) { return @{ Rows = @{}; Errors = @($errors); Delimiter = $delimiter } }
    $known = @{}
    foreach ($item in @($Snapshot.Items)) { $known[[string]$item.ItemId] = $item }
    $result = @{}
    $line = 1
    foreach ($row in $rows) {
        $line++
        $id = ([string]$row.ItemId).Trim()
        if (-not $id) { continue }
        if (-not $known.ContainsKey($id)) { $errors.Add("Line ${line}: item '$id' is not in the snapshot $($Snapshot.CollectId)."); continue }
        if ('CollectId' -in $names -and $row.CollectId -and ([string]$row.CollectId).Trim() -ne [string]$Snapshot.CollectId) {
            $errors.Add("Line ${line}: the row comes from the collection $($row.CollectId), not from the snapshot $($Snapshot.CollectId). Use the Selection.csv of the same Collect run."); continue
        }
        $include = ConvertTo-XsmBoolean ([string]$row.Include)
        if ($null -eq $include) { $errors.Add("Line ${line}: Include must be Yes or No (value: '$($row.Include)')."); continue }
        if ($result.ContainsKey($id)) { $errors.Add("Line ${line}: item '$id' appears twice."); continue }
        $result[$id] = @{ Include = $include; Level = ([string]$row.Level).Trim(); Scope = ([string]$row.Scope).Trim(); Line = $line }
    }
    return @{ Rows = $result; Errors = @($errors); Delimiter = $delimiter }
}
