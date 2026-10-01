<#
    X-TAP Sharing Migration - configuration and feature catalogue.

    The catalogue maps each feature (Free/Busy, MailTips, calendar sharing, anonymous calendar
    publishing) and level to the Microsoft Graph capability name, and each Exchange Online setting to a
    level. It is the only place to change when Microsoft adds a capability.
#>

# ---------------------------------------------------------------------------------------------------
# Feature catalogue. Levels are listed from the least to the most detailed.
#   Targets : Partner = partner policy (one external tenant); Default = default policy (all tenants / anonymous)
# ---------------------------------------------------------------------------------------------------
$script:FeatureCatalog = [ordered]@{
    FreeBusy                 = @{
        Label   = 'Free/Busy'
        Targets = @('Partner')
        Levels  = [ordered]@{ Basic = 'crossTenantCalendarAvailabilityBasic'; LimitedDetails = 'crossTenantCalendarAvailabilityLimitedDetails' }
        Text    = @{ Basic = 'free/busy, time only'; LimitedDetails = 'free/busy with subject and location' }
    }
    MailTips                 = @{
        Label   = 'MailTips'
        Targets = @('Partner')
        Levels  = [ordered]@{ Limited = 'crossTenantMailTipsLimited'; All = 'crossTenantMailTipsAll' }
        Text    = @{ Limited = 'MailTips that prevent an NDR or show an automatic reply'; All = 'all MailTips' }
    }
    CalendarSharing          = @{
        Label   = 'Calendar sharing'
        Targets = @('Partner', 'Default')
        Levels  = [ordered]@{ Simple = 'crossTenantCalendarSharingFreeBusySimple'; Detail = 'crossTenantCalendarSharingFreeBusyDetail'; Reviewer = 'crossTenantCalendarSharingFreeBusyReviewer' }
        Text    = @{ Simple = 'calendar shared, time only'; Detail = 'calendar shared with subject and location'; Reviewer = 'calendar shared with all details' }
    }
    AnonymousCalendarSharing = @{
        Label   = 'Anonymous calendar publishing'
        Targets = @('Default')
        Levels  = [ordered]@{ Simple = 'anonymousCalendarSharingFreeBusySimple'; Detail = 'anonymousCalendarSharingFreeBusyDetail'; Reviewer = 'anonymousCalendarSharingFreeBusyReviewer' }
        Text    = @{ Simple = 'published calendar, time only'; Detail = 'published calendar with subject and location'; Reviewer = 'published calendar with all details' }
    }
}

# Exchange Online values -> level of the catalogue.
$script:ExchangeLevelMap = @{
    FreeBusyAccessLevel = @{ AvailabilityOnly = 'Basic'; LimitedDetails = 'LimitedDetails' }
    MailTipsAccessLevel = @{ Limited = 'Limited'; All = 'All' }
    SharingAction       = @{ CalendarSharingFreeBusySimple = 'Simple'; CalendarSharingFreeBusyDetail = 'Detail'; CalendarSharingFreeBusyReviewer = 'Reviewer' }
}

function Get-XsmFeatureNames { return @($script:FeatureCatalog.Keys) }

function Get-XsmCapabilityName {
    <# Graph capability name of a feature and level, e.g. FreeBusy + Basic -> crossTenantCalendarAvailabilityBasic. #>
    param([Parameter(Mandatory)][string]$Feature, [Parameter(Mandatory)][string]$Level)
    $entry = $script:FeatureCatalog[$Feature]
    if (-not $entry) { throw "Unknown feature '$Feature'." }
    foreach ($key in $entry.Levels.Keys) { if ($key -ieq $Level) { return $entry.Levels[$key] } }
    throw "Unknown level '$Level' for $Feature (valid: $(@($entry.Levels.Keys) -join ', '))."
}

function Get-XsmCapabilityInfo {
    <# Feature and level of a Graph capability name (case-insensitive); $null for a capability outside the catalogue. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    foreach ($feature in $script:FeatureCatalog.Keys) {
        $levels = $script:FeatureCatalog[$feature].Levels
        foreach ($level in $levels.Keys) {
            if ($levels[$level] -ieq $Name) { return @{ Feature = $feature; Level = $level; Name = $levels[$level] } }
        }
    }
    return $null
}

function Get-XsmLevelRank {
    <# Position of a level in its feature (0 = least detailed). #>
    param([Parameter(Mandatory)][string]$Feature, [Parameter(Mandatory)][string]$Level)
    $i = 0
    foreach ($key in $script:FeatureCatalog[$Feature].Levels.Keys) { if ($key -ieq $Level) { return $i }; $i++ }
    return -1
}

function Resolve-XsmLevelName {
    <# Canonical spelling of a level for a feature, or $null when the level does not exist. #>
    param([Parameter(Mandatory)][string]$Feature, [AllowNull()][AllowEmptyString()][string]$Level)
    if (-not $Level) { return $null }
    foreach ($key in $script:FeatureCatalog[$Feature].Levels.Keys) { if ($key -ieq $Level.Trim()) { return $key } }
    return $null
}

# ---------------------------------------------------------------------------------------------------
# Scope values (configuration and Selection.csv):
#   All                         every user of the tenant
#   <object ID>                 an existing Entra security group
#   Group:<key>                 a group of the Groups section of the configuration (created by -Phase Entra if Create = $true)
#   Group:<display name>        an existing Entra security group, by display name (must be unique)
#   SharingPolicy:<policy name> an assigned security group with the mailboxes of this sharing policy (created by -Phase Entra)
#   Several values: separated by |   (for example  Group:Sales | Group:Marketing)
# ---------------------------------------------------------------------------------------------------
$script:GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

function ConvertTo-XsmScopeSpec {
    <#
    .SYNOPSIS
        Turns a scope value into a list of scope specifications. Errors are returned as Kind = 'Invalid'.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value, [Parameter(Mandatory)]$Settings)
    $specs = [Collections.Generic.List[hashtable]]::new()
    if (-not $Value -or -not $Value.Trim()) { $specs.Add(@{ Kind = 'Invalid'; Token = ''; Text = 'empty scope'; Message = 'The scope is empty.' }); return , $specs.ToArray() }
    foreach ($raw in $Value.Split('|')) {
        $token = $raw.Trim()
        if (-not $token) { continue }
        if ($token -ieq 'All') { $specs.Add(@{ Kind = 'All'; Token = 'All'; Text = 'All users' }); continue }
        if ($token -match $script:GuidPattern) { $specs.Add(@{ Kind = 'Id'; Id = $token.ToLowerInvariant(); Token = $token.ToLowerInvariant(); Text = "group $($token.ToLowerInvariant())" }); continue }
        if ($token -match '^(?i)group:(.+)$') {
            $name = $Matches[1].Trim()
            $groupKey = @($Settings.Groups.Keys | Where-Object { $_ -ieq $name }) | Select-Object -First 1
            if ($groupKey) {
                $g = $Settings.Groups[$groupKey]
                $specs.Add(@{ Kind = 'Config'; Key = $groupKey; DisplayName = $g.DisplayName; Id = $g.Id; Create = $g.Create; MembershipRule = $g.MembershipRule; Description = $g.Description; Token = "Group:$groupKey"; Text = "group $($g.DisplayName)" })
            } else {
                $specs.Add(@{ Kind = 'Name'; DisplayName = $name; Token = "Group:$name"; Text = "group $name" })
            }
            continue
        }
        if ($token -match '^(?i)sharingpolicy:(.+)$') {
            $policy = $Matches[1].Trim()
            $display = ($Settings.SharingPolicyGroups.NameFormat -f $policy)
            $specs.Add(@{ Kind = 'SharingPolicy'; Policy = $policy; DisplayName = $display; Create = $Settings.SharingPolicyGroups.Create; Token = "SharingPolicy:$policy"; Text = "group $display (mailboxes of the sharing policy $policy)" })
            continue
        }
        if ($token -match '^(?i)unresolved:(.*)$') {
            $specs.Add(@{ Kind = 'Invalid'; Token = $token; Text = "unresolved $($Matches[1])"; Message = "The Exchange scope group '$($Matches[1])' could not be matched to a Microsoft Entra group: choose a scope (Selection.csv, Scope column, or the configuration)." })
            continue
        }
        $specs.Add(@{ Kind = 'Invalid'; Token = $token; Text = $token; Message = "Scope value '$token' not understood. Use All, an object ID, Group:<name>, or SharingPolicy:<policy name>." })
    }
    if (-not $specs.Count) { $specs.Add(@{ Kind = 'Invalid'; Token = $Value; Text = $Value; Message = 'The scope is empty.' }) }
    # "All" covers everything: the other values would be redundant.
    $all = @($specs | Where-Object Kind -eq 'All')
    if ($all.Count -and $specs.Count -gt 1 -and -not @($specs | Where-Object Kind -eq 'Invalid').Count) { return , @($all[0]) }
    return , $specs.ToArray()
}

function Format-XsmScope {
    <# Short text of a list of scope specifications, for the console and the report. #>
    param([AllowNull()][object[]]$Specs)
    if (-not $Specs) { return '-' }
    return (@($Specs | ForEach-Object { if ($_.Kind -eq 'All') { 'All users' } elseif ($_.DisplayName) { $_.DisplayName } elseif ($_.Id) { $_.Id } else { $_.Token } }) -join ' + ')
}

# ---------------------------------------------------------------------------------------------------
# Configuration file
# ---------------------------------------------------------------------------------------------------
function Resolve-XsmPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Import-XsmConfiguration {
    <#
    .SYNOPSIS
        Reads the configuration file, checks every value and returns it normalized, with absolute paths.
        All problems are reported together so the administrator can fix them in one go.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Root = $script:ToolRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { $config = Import-PowerShellDataFile -LiteralPath $Path }
    catch { throw "The configuration file is not valid PowerShell data ($Path): $($_.Exception.Message)" }

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($section in 'Tenant', 'Authentication', 'Collection', 'Features', 'Partners', 'Groups', 'SharingPolicyGroups', 'Entra', 'Apply', 'Output', 'Logging') {
        if (-not $config.ContainsKey($section)) { $errors.Add("Section '$section' is missing.") }
    }
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }

    function Get-Value([hashtable]$Section, [string]$Name, [string]$Key, $Default) {
        if ($Section -and $Section.ContainsKey($Key) -and $null -ne $Section[$Key]) { return $Section[$Key] }
        return $Default
    }
    function Get-Bool([hashtable]$Section, [string]$Name, [string]$Key, [bool]$Default) {
        $v = Get-Value $Section $Name $Key $Default
        if ($v -isnot [bool]) { $errors.Add("$Name.$Key must be `$true or `$false (current value: '$v')."); return $Default }
        return $v
    }
    function Get-Text([hashtable]$Section, [string]$Name, [string]$Key, [string]$Default = '') {
        $v = Get-Value $Section $Name $Key $Default
        if ($v -isnot [string]) { $errors.Add("$Name.$Key must be a text between quotes."); return $Default }
        return $v.Trim()
    }

    $settings = [ordered]@{ Path = [IO.Path]::GetFullPath($Path); Root = $Root }

    # Tenant ---------------------------------------------------------------------------------------
    $t = $config.Tenant
    $settings.Tenant = @{ TenantId = (Get-Text $t 'Tenant' 'TenantId').ToLowerInvariant(); Organization = Get-Text $t 'Tenant' 'Organization' }
    if (-not $settings.Tenant.TenantId) { $errors.Add('Tenant.TenantId is required (GUID of the tenant to configure).') }
    elseif ($settings.Tenant.TenantId -notmatch $script:GuidPattern) { $errors.Add("Tenant.TenantId must be a GUID (current value: '$($settings.Tenant.TenantId)').") }
    if ($settings.Tenant.Organization -and $settings.Tenant.Organization -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { $errors.Add("Tenant.Organization must be a domain name such as contoso.onmicrosoft.com (current value: '$($settings.Tenant.Organization)').") }

    # Authentication -------------------------------------------------------------------------------
    $a = $config.Authentication
    $settings.Authentication = @{
        Mode                  = Get-Text $a 'Authentication' 'Mode' 'Interactive'
        ExchangeAdmin         = Get-Text $a 'Authentication' 'ExchangeAdmin'
        EntraAdmin            = Get-Text $a 'Authentication' 'EntraAdmin'
        DisableWAM            = Get-Bool $a 'Authentication' 'DisableWAM' $true
        GraphClientId         = Get-Text $a 'Authentication' 'GraphClientId'
        AppId                 = Get-Text $a 'Authentication' 'AppId'
        CertificateThumbprint = Get-Text $a 'Authentication' 'CertificateThumbprint'
    }
    if ($settings.Authentication.Mode -notin 'Interactive', 'DeviceCode', 'Certificate') { $errors.Add("Authentication.Mode must be Interactive, DeviceCode or Certificate (current value: '$($settings.Authentication.Mode)').") }
    if ($settings.Authentication.GraphClientId -and $settings.Authentication.GraphClientId -notmatch $script:GuidPattern) { $errors.Add('Authentication.GraphClientId must be empty or an application (client) ID.') }
    if ($settings.Authentication.Mode -eq 'Certificate') {
        if ($settings.Authentication.AppId -notmatch $script:GuidPattern) { $errors.Add('Authentication.AppId is required in certificate mode (application ID).') }
        if (-not $settings.Authentication.CertificateThumbprint) { $errors.Add('Authentication.CertificateThumbprint is required in certificate mode.') }
        if (-not $settings.Tenant.Organization) { $errors.Add('Tenant.Organization is required in certificate mode (Connect-ExchangeOnline -Organization needs the xxx.onmicrosoft.com name).') }
    }

    # Collection -----------------------------------------------------------------------------------
    $c = $config.Collection
    $settings.Collection = @{
        MailboxAssignments            = Get-Bool $c 'Collection' 'MailboxAssignments' $true
        BackupExchangeObjects         = Get-Bool $c 'Collection' 'BackupExchangeObjects' $true
        HybridRelationshipNamePattern = Get-Text $c 'Collection' 'HybridRelationshipNamePattern' '^O365 to On-premises'
        Microsoft365Endpoints         = @(Get-Value $c 'Collection' 'Microsoft365Endpoints' @('outlook.com', 'office365.com', 'office365.us', 'outlook.cn') | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    try { [void][regex]::new($settings.Collection.HybridRelationshipNamePattern) } catch { $errors.Add("Collection.HybridRelationshipNamePattern is not a valid regular expression: $($_.Exception.Message)") }
    if (-not $settings.Collection.Microsoft365Endpoints.Count) { $errors.Add('Collection.Microsoft365Endpoints must list at least one host name (outlook.com ...).') }

    # Groups (before the scopes that reference them) -----------------------------------------------
    $settings.Groups = [ordered]@{}
    $groups = $config.Groups
    if ($groups -isnot [hashtable] -and $groups -isnot [System.Collections.Specialized.OrderedDictionary]) { $errors.Add('Groups must be @{ } (empty or one entry per group).'); $groups = @{} }
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $g = $groups[$key]; $name = "Groups.$key"
        if ($g -isnot [hashtable]) { $errors.Add("$name must be @{ DisplayName = '...' ... }."); continue }
        $entry = @{
            Key            = $key
            DisplayName    = Get-Text $g $name 'DisplayName'
            Description    = Get-Text $g $name 'Description'
            Id             = (Get-Text $g $name 'Id').ToLowerInvariant()
            Create         = Get-Bool $g $name 'Create' $false
            MembershipRule = Get-Text $g $name 'MembershipRule'
            MailNickname   = Get-Text $g $name 'MailNickname'
        }
        if (-not $entry.DisplayName -and -not $entry.Id) { $errors.Add("$name needs DisplayName (or Id for an existing group).") }
        if ($entry.Id -and $entry.Id -notmatch $script:GuidPattern) { $errors.Add("$name.Id must be the object ID of the group.") }
        if ($entry.Create -and -not $entry.DisplayName) { $errors.Add("$name.DisplayName is required when Create = `$true.") }
        if ($entry.Create -and $entry.Id) { $errors.Add("$name cannot have both Id (existing group) and Create = `$true.") }
        if ($key -notmatch '^[A-Za-z0-9._-]+$') { $errors.Add("Groups key '$key' may contain only letters, digits, dot, dash and underscore.") }
        $settings.Groups[$key] = $entry
    }

    # Sharing policy groups ------------------------------------------------------------------------
    $s = $config.SharingPolicyGroups
    $settings.SharingPolicyGroups = @{ Create = Get-Bool $s 'SharingPolicyGroups' 'Create' $true; NameFormat = Get-Text $s 'SharingPolicyGroups' 'NameFormat' 'SG-XTAP-SharingPolicy-{0}' }
    if ($settings.SharingPolicyGroups.NameFormat -notmatch '\{0\}') { $errors.Add('SharingPolicyGroups.NameFormat must contain {0} (replaced by the policy name).') }

    # Features --------------------------------------------------------------------------------------
    $settings.Features = [ordered]@{}
    foreach ($feature in $script:FeatureCatalog.Keys) {
        $f = $config.Features[$feature]; $name = "Features.$feature"
        if ($f -isnot [hashtable]) { $errors.Add("$name is missing (@{ Migrate = `$true; Level = 'AsDiscovered'; Scope = 'AsDiscovered' })."); $f = @{} }
        $entry = @{ Migrate = Get-Bool $f $name 'Migrate' $true; Level = Get-Text $f $name 'Level' 'AsDiscovered'; Scope = Get-Text $f $name 'Scope' 'AsDiscovered' }
        if ($entry.Level -ine 'AsDiscovered') {
            $canonical = Resolve-XsmLevelName $feature $entry.Level
            if (-not $canonical) { $errors.Add("$name.Level must be AsDiscovered or $(@($script:FeatureCatalog[$feature].Levels.Keys) -join ', ') (current value: '$($entry.Level)').") } else { $entry.Level = $canonical }
        } else { $entry.Level = 'AsDiscovered' }
        if ($entry.Scope -ine 'AsDiscovered') {
            foreach ($spec in (ConvertTo-XsmScopeSpec $entry.Scope ([pscustomobject]$settings))) { if ($spec.Kind -eq 'Invalid') { $errors.Add("$name.Scope: $($spec.Message)") } }
        } else { $entry.Scope = 'AsDiscovered' }
        $settings.Features[$feature] = $entry
    }

    # Partners --------------------------------------------------------------------------------------
    $settings.Partners = [Collections.Generic.List[hashtable]]::new()
    $index = 0
    foreach ($p in @($config.Partners)) {
        $index++; $name = "Partners[$index]"
        if ($null -eq $p) { continue }
        if ($p -isnot [hashtable]) { $errors.Add("$name must be @{ Match = '...' ... }."); continue }
        $entry = @{ Match = (Get-Text $p $name 'Match').ToLowerInvariant(); TenantId = (Get-Text $p $name 'TenantId').ToLowerInvariant(); Name = Get-Text $p $name 'Name'; Include = $null; Features = @{} }
        if ($entry.TenantId -and $entry.TenantId -notmatch $script:GuidPattern) { $errors.Add("$name.TenantId must be the tenant ID (GUID) confirmed by the partner (current value: '$($entry.TenantId)').") }
        if (-not $entry.Match) { $entry.Match = $entry.TenantId }
        if (-not $entry.Match) { $errors.Add("$name needs Match (a domain of the partner) and/or TenantId (tenant ID confirmed by the partner).") }
        if ($entry.TenantId -and $entry.Match -match $script:GuidPattern -and $entry.Match -ne $entry.TenantId) { $errors.Add("$name.Match is a tenant ID different from $name.TenantId.") }
        if ($p.ContainsKey('Include')) {
            if ($p.Include -isnot [bool]) { $errors.Add("$name.Include must be `$true or `$false.") } else { $entry.Include = $p.Include }
        }
        foreach ($key in $p.Keys) {
            if ($key -in 'Match', 'Include', 'Name', 'TenantId') { continue }
            if (-not $script:FeatureCatalog.Contains($key)) { $errors.Add("$name.$key is not a feature (valid: $(@($script:FeatureCatalog.Keys) -join ', '))."); continue }
            $f = $p[$key]
            if ($f -isnot [hashtable]) { $errors.Add("$name.$key must be @{ Level = '...'; Scope = '...' }."); continue }
            $fe = @{}
            if ($f.ContainsKey('Migrate')) { if ($f.Migrate -isnot [bool]) { $errors.Add("$name.$key.Migrate must be `$true or `$false.") } else { $fe.Migrate = $f.Migrate } }
            if ($f.ContainsKey('Level')) {
                $canonical = Resolve-XsmLevelName $key ([string]$f.Level)
                if (-not $canonical) { $errors.Add("$name.$key.Level must be $(@($script:FeatureCatalog[$key].Levels.Keys) -join ', ') (current value: '$($f.Level)').") } else { $fe.Level = $canonical }
            }
            if ($f.ContainsKey('Scope')) {
                $fe.Scope = [string]$f.Scope
                foreach ($spec in (ConvertTo-XsmScopeSpec $fe.Scope ([pscustomobject]$settings))) { if ($spec.Kind -eq 'Invalid') { $errors.Add("$name.$key.Scope: $($spec.Message)") } }
            }
            $entry.Features[$key] = $fe
        }
        $settings.Partners.Add($entry)
    }

    # Entra, Apply ----------------------------------------------------------------------------------
    $settings.Entra = @{
        RequireConfirmedPartners = Get-Bool $config.Entra 'Entra' 'RequireConfirmedPartners' $true
        ReplaceRestrictedTrust   = Get-Bool $config.Entra 'Entra' 'ReplaceRestrictedTrust' $false
    }
    $settings.Apply = @{
        ExistingCapability = Get-Text $config.Apply 'Apply' 'ExistingCapability' 'Keep'
        DisableOtherLevels = Get-Bool $config.Apply 'Apply' 'DisableOtherLevels' $false
    }
    $canonicalExisting = @('Keep', 'Merge', 'Replace') | Where-Object { $_ -ieq $settings.Apply.ExistingCapability }
    if (-not $canonicalExisting) { $errors.Add("Apply.ExistingCapability must be Keep, Merge or Replace (current value: '$($settings.Apply.ExistingCapability)').") } else { $settings.Apply.ExistingCapability = $canonicalExisting }
    if ($config.Apply -and $config.Apply.ContainsKey('UpdateExisting')) { $errors.Add("Apply.UpdateExisting is replaced by Apply.ExistingCapability = 'Keep' | 'Merge' | 'Replace'.") }

    # Output, Logging -------------------------------------------------------------------------------
    $o = $config.Output
    $settings.Output = @{ Path = Get-Text $o 'Output' 'Path' '.\output'; CsvDelimiter = Get-Text $o 'Output' 'CsvDelimiter' ';'; TimeZone = Get-Text $o 'Output' 'TimeZone' 'UTC' }
    if ($settings.Output.CsvDelimiter.Length -ne 1) { $errors.Add("Output.CsvDelimiter must be one character (current value: '$($settings.Output.CsvDelimiter)').") }
    try { $settings.Output.Zone = [TimeZoneInfo]::FindSystemTimeZoneById($settings.Output.TimeZone) }
    catch { $errors.Add("Output.TimeZone '$($settings.Output.TimeZone)' is not a known time zone (examples: Europe/Paris, UTC)."); $settings.Output.Zone = [TimeZoneInfo]::Utc }
    $l = $config.Logging
    $settings.Logging = @{ Path = Get-Text $l 'Logging' 'Path' '.\logs'; RetentionDays = Get-Value $l 'Logging' 'RetentionDays' 90 }
    if ($settings.Logging.RetentionDays -isnot [int] -or $settings.Logging.RetentionDays -lt 0) { $errors.Add('Logging.RetentionDays must be a whole number, 0 or more (0 = keep every log file).') }

    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }
    $settings.Output.Path = Resolve-XsmPath $settings.Output.Path $Root
    $settings.Logging.Path = Resolve-XsmPath $settings.Logging.Path $Root
    # Features of this run (-Feature): empty = every feature allowed by the configuration.
    $settings.RunFeatures = @()
    return [pscustomobject]$settings
}
