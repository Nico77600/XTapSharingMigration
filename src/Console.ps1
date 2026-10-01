<#
    X-TAP Sharing Migration - console and log.

    What the administrator sees: title card, numbered steps, result lines, aligned tables and the final
    summary card. Every line written to the console is also written to the log file, without colours
    or icons.

    - Colours (ANSI) are disabled when the output is redirected (scheduled task, log capture) or when
      the NO_COLOR environment variable is set; XSM_FORCE_COLOR=1 forces them.
    - Icons: emoji in modern terminals (Windows Terminal, VS Code), simple symbols elsewhere. The
      emoji are chosen among those always two columns wide (no variation selector) so frames and
      columns stay aligned. The symbols used outside the modern terminals all exist in Consolas and
      Lucida Console (code page 437 or Latin-1 repertoire): the classic console has no font fallback.
      Force a style with the environment variable XSM_ICONS = Emoji | Symbols | Ascii.
#>

$script:C = @{ Reset = ''; Bold = ''; Dim = ''; Accent = ''; AccentBg = ''; Cyan = ''; Green = ''; Yellow = ''; Red = ''; White = ''; Blue = '' }
if ($env:XSM_FORCE_COLOR -eq '1' -or (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR)) {
    $e = [char]27
    $script:C = @{
        Reset = "$e[0m"; Bold = "$e[1m"; Dim = "$e[90m"; White = "$e[97m"
        Accent = "$e[38;2;214;62;115m"; AccentBg = "$e[48;2;177;31;75m$e[97m"
        Cyan = "$e[38;2;97;214;214m"; Green = "$e[38;2;80;200;120m"; Yellow = "$e[38;2;240;200;90m"; Red = "$e[38;2;240;90;90m"
        Blue = "$e[38;2;110;170;255m"
    }
}
$script:IconStyle = if ($env:XSM_ICONS -in 'Emoji', 'Symbols', 'Ascii') { $env:XSM_ICONS }
    elseif ([Console]::IsOutputRedirected) { 'Symbols' }
    elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') { 'Emoji' }
    else { 'Symbols' }

function Get-XsmIconSet {
    <# Icons of one console style. Symbols: only characters of the classic console fonts. #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    $u = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    switch ($Style) {
        'Emoji' { return @{
                Logo = & $u 0x1F91D; Ok = & $u 0x2705; Warn = (& $u 0x26A0) + [char]0xFE0F; Fail = & $u 0x274C
                Info = & $u 0x1F539; Skip = & $u 0x23E9; Exchange = & $u 0x1F4E7; Graph = & $u 0x1F517
                Key = & $u 0x1F510; Plan = & $u 0x1F50E; Apply = & $u 0x1F527; Report = & $u 0x1F4CA
                Calendar = & $u 0x1F4C5; File = & $u 0x1F4C4; Folder = & $u 0x1F4C1; Clock = & $u 0x23F3
                Target = & $u 0x1F3AF; Log = & $u 0x1F4DD; Done = & $u 0x1F389; People = & $u 0x1F465
                Partner = & $u 0x1F310; Snapshot = & $u 0x1F4BE; Create = & $u 0x2795; Update = & $u 0x1F504
                Same = & $u 0x26AA; Block = & $u 0x26D4; Question = & $u 0x2753; Lock = & $u 0x1F512
            } }
        'Symbols' { return @{
                Logo = & $u 0x2666; Ok = & $u 0x221A; Warn = & $u 0x25B2; Fail = & $u 0x00D7; Info = & $u 0x2022
                Skip = & $u 0x00BB; Exchange = '@'; Graph = & $u 0x2261; Key = & $u 0x2194; Plan = & $u 0x25BA
                Apply = & $u 0x25BA; Report = & $u 0x2261; Calendar = & $u 0x263C; File = & $u 0x25AC; Folder = & $u 0x2302
                Clock = & $u 0x25CB; Target = & $u 0x25D9; Log = & $u 0x00B6; Done = & $u 0x221A; People = & $u 0x2192
                Partner = & $u 0x2194; Snapshot = & $u 0x25A0; Create = '+'; Update = '~'; Same = '='
                Block = & $u 0x00D7; Question = '?'; Lock = & $u 0x25A0
            } }
        default { return @{
                Logo = '*'; Ok = '+'; Warn = '!'; Fail = 'x'; Info = '-'; Skip = '>'; Exchange = '@'; Graph = '='; Key = '@'
                Plan = '?'; Apply = '>'; Report = '='; Calendar = ':'; File = '-'; Folder = '>'; Clock = '~'; Target = 'o'
                Log = '='; Done = '*'; People = '&'; Partner = '<>'; Snapshot = '#'; Create = '+'; Update = '~'; Same = '='
                Block = 'x'; Question = '?'; Lock = '#'
            } }
    }
}

function Get-XsmFrameSet {
    <# Frame characters: rounded corners with emoji (modern terminals), square corners elsewhere (present in every console font). #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    if ($Style -eq 'Ascii') { return @{ TopLeft = [char]'+'; TopRight = [char]'+'; BottomLeft = [char]'+'; BottomRight = [char]'+'; Horizontal = [char]'-'; Vertical = [char]'|' } }
    if ($Style -eq 'Symbols') { return @{ TopLeft = [char]0x250C; TopRight = [char]0x2510; BottomLeft = [char]0x2514; BottomRight = [char]0x2518; Horizontal = [char]0x2500; Vertical = [char]0x2502 } }
    return @{ TopLeft = [char]0x256D; TopRight = [char]0x256E; BottomLeft = [char]0x2570; BottomRight = [char]0x256F; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
}

$script:Icons = Get-XsmIconSet $script:IconStyle
$script:Frame = Get-XsmFrameSet $script:IconStyle
# Emoji are two columns wide in the console; symbols are one: pad symbols so text stays aligned.
$script:IconPad = if ($script:IconStyle -eq 'Emoji') { ' ' } else { '  ' }
$script:IconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
$script:LogWriter = $null
$script:LogPath = $null
$script:Dot = [char]0x00B7
$script:Arrow = [char]0x2192

function Get-XsmIcon {
    param([Parameter(Mandatory)][string]$Name)
    $icon = $script:Icons[$Name]
    if (-not $icon) { $icon = $script:Icons['Info'] }
    # Ascii icons may be two characters wide ('<>'): pad to a fixed width.
    if ($script:IconStyle -eq 'Ascii') { return $icon.PadRight(2) + ' ' }
    return $icon + $script:IconPad
}

function Format-XsmDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    # 0.0 (not 0): with an integer first argument PowerShell picks Math.Max(int, int) and drops the decimals.
    $t = [TimeSpan]::FromTicks([long]([Math]::Max(0.0, $Seconds) * 10000000))
    if ($t.TotalHours -ge 1) { return '{0} h {1:00} min' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0} min {1:00} s' -f $t.Minutes, $t.Seconds }
    return '{0:0.0} s' -f $t.TotalSeconds
}

function Format-XsmText {
    <# Shortens a text to a column width, with an ellipsis, and pads it. #>
    param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Width)
    if ($null -eq $Text) { $Text = '' }
    $Text = $Text -replace '[\r\n\t]+', ' '
    if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
    if ($Width -le 1) { return $Text.Substring(0, $Width) }
    return $Text.Substring(0, $Width - 1) + [char]0x2026
}

function Start-XsmLog {
    <# Opens (or continues) today's log file and deletes log files older than the retention. #>
    param([Parameter(Mandatory)][string]$Directory, [int]$RetentionDays = 90)
    [void][IO.Directory]::CreateDirectory($Directory)
    $script:LogPath = Join-Path $Directory ('XTapSharingMigration_{0:yyyyMMdd}.log' -f (Get-Date))
    $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:LogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $script:LogWriter.AutoFlush = $true
    if ($RetentionDays -gt 0) {
        $limit = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $Directory -Filter 'XTapSharingMigration_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $limit | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $script:LogPath
}

function Stop-XsmLog {
    if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
}

function Write-XsmLog {
    <# Writes one line to the log file only (never to the console). #>
    param([ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO', [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if ($script:LogWriter) {
        $script:LogWriter.WriteLine(('{0:yyyy-MM-ddTHH:mm:ss.fffzzz} [{1,-5}] {2}' -f (Get-Date), $Level, $Message))
    }
}

function Write-XsmBanner {
    <#
    .SYNOPSIS
        Title card at the start of an execution:

          ╭──────────────────────────────────────────────────────────────────────────────╮
          │  🤝  X-TAP Sharing Migration                      v1.0.1 · Nicolas Fabert    │
          │     Free/Busy · MailTips · calendar sharing → Microsoft 365 X-TAP            │
          ╰──────────────────────────────────────────────────────────────────────────────╯
             🎯  Mode        Collect
    .PARAMETER Details
        Ordered list of rows: key = label, value = @(IconName, Text) or plain text.
    #>
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle, [System.Collections.Specialized.OrderedDictionary]$Details)
    $C = $script:C; $F = $script:Frame; $width = 78
    $right = "v$($script:ToolVersion) $($script:Dot) $($script:ToolAuthor)"
    $left = "  $($script:Icons.Logo)  $Title"
    $leftWidth = $left.Length - $script:Icons.Logo.Length + $script:IconWidth
    $gap = [Math]::Max(1, $width - $leftWidth - $right.Length - 2)
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.TopLeft, [string]::new($F.Horizontal, $width), $F.TopRight, $C.Reset)
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}{11}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Bold, $left, $C.Reset, [string]::new(' ', $gap), $C.Dim, $right, '  ', ($C.Accent + $F.Vertical), $C.Reset)
    if ($Subtitle) {
        $sub = "     $Subtitle"
        Write-Host ("  {0}{1}{2}{3}{4}{5}{0}{6}{2}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Dim, (Format-XsmText $sub $width), $C.Reset, $F.Vertical)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            $icon, $text = if ($value -is [array]) { (Get-XsmIcon $value[0]), $value[1] } else { '   ', $value }
            Write-Host ("     {0}{1}{2,-11}{3} {4}" -f $icon, $C.Dim, $key, $C.Reset, $text)
        }
    }
    Write-XsmLog 'STEP' "=== $Title v$($script:ToolVersion) ==="
    if ($Details) { foreach ($key in $Details.Keys) { $v = $Details[$key]; Write-XsmLog 'INFO' ("{0}: {1}" -f $key, $(if ($v -is [array]) { $v[1] } else { $v })) } }
}

function Write-XsmStep {
    <# Step header with a coloured number pill and an icon:   2/5  📧  Reading Exchange Online #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int]$Total, [Parameter(Mandatory)][string]$Title, [string]$Icon = 'Info')
    $C = $script:C
    Write-Host ''
    Write-Host ("  {0} {1}/{2} {3} {4}{5}{6}{3}" -f $C.AccentBg, $Number, $Total, $C.Reset, (Get-XsmIcon $Icon), $C.Bold, $Title)
    Write-XsmLog 'STEP' "[$Number/$Total] $Title"
}

function Write-XsmSection {
    <# Sub-title inside a step (for example 'Phase Entra'). #>
    param([Parameter(Mandatory)][string]$Title, [string]$Icon = 'Target')
    Write-Host ''
    Write-Host ("      {0}{1}{2}{3}" -f (Get-XsmIcon $Icon), $script:C.Bold, $Title, $script:C.Reset)
    Write-XsmLog 'INFO' "--- $Title ---"
}

function Write-XsmItem {
    <# One indented result line with a status icon, also written to the log. #>
    param([ValidateSet('Ok', 'Warn', 'Fail', 'Info', 'Skip')][string]$Status = 'Info', [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon, [int]$Indent = 6)
    $color = @{ Ok = $script:C.Green; Warn = $script:C.Yellow; Fail = $script:C.Red; Info = ''; Skip = $script:C.Dim }[$Status]
    $level = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO' }[$Status]
    $symbol = Get-XsmIcon $(if ($Icon) { $Icon } else { $Status })
    $textColor = if ($Status -in 'Warn', 'Fail', 'Skip') { $color } else { '' }
    Write-Host ("{0}{1}{2}{3}{4}{5}{3}" -f (' ' * $Indent), $color, $symbol, $script:C.Reset, $textColor, $Text)
    Write-XsmLog $level $Text
}

function Write-XsmTable {
    <#
    .SYNOPSIS
        Aligned table, one row per object, with a status icon in front of each row.
    .PARAMETER Columns
        Array of @{ Name = 'Header'; Property = 'PropertyName'; Width = 20 }. A column with Width 0 takes
        the remaining width of the console.
    .PARAMETER StatusProperty
        Property holding Ok | Warn | Fail | Info | Skip (colour of the row).
    .PARAMETER IconProperty
        Optional property holding an icon name that replaces the status icon.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Columns,
        [AllowEmptyCollection()][AllowNull()][object[]]$Rows,
        [string]$StatusProperty = 'Status',
        [string]$IconProperty,
        [int]$Indent = 6,
        [int]$MaxWidth = 160
    )
    $C = $script:C
    if (-not $Rows -or -not $Rows.Count) { return }
    $consoleWidth = try { [Math]::Min($MaxWidth, [Console]::WindowWidth - 1) } catch { $MaxWidth }
    if ($consoleWidth -lt 80) { $consoleWidth = 120 }
    $fixed = [int](($Columns | ForEach-Object { [int]$_.Width } | Measure-Object -Sum).Sum) + 2 * $Columns.Count
    $last = [Math]::Max(20, $consoleWidth - $Indent - 3 - $fixed)
    $pad = ' ' * $Indent
    $widthOf = { param($col) if ([int]$col.Width) { [int]$col.Width } else { $last } }
    $header = ($Columns | ForEach-Object { Format-XsmText $_.Name (& $widthOf $_) }) -join '  '
    Write-Host ("{0}{1}{2}{3}{4}" -f $pad, $C.Dim, (' ' * ($script:IconWidth + $script:IconPad.Length)), $header.TrimEnd(), $C.Reset)
    foreach ($row in $Rows) {
        $status = [string]$row.$StatusProperty
        if ($status -notin 'Ok', 'Warn', 'Fail', 'Info', 'Skip') { $status = 'Info' }
        $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red; Info = $C.Blue; Skip = $C.Dim }[$status]
        $iconName = if ($IconProperty -and $row.$IconProperty) { [string]$row.$IconProperty } else { $status }
        $cells = foreach ($col in $Columns) {
            $value = $row.($col.Property)
            if ($value -is [array]) { $value = $value -join ', ' }
            Format-XsmText ([string]$value) (& $widthOf $col)
        }
        $textColor = if ($status -eq 'Skip') { $C.Dim } else { '' }
        Write-Host ("{0}{1}{2}{3}{4}{5}{3}" -f $pad, $color, (Get-XsmIcon $iconName), $C.Reset, $textColor, (($cells -join '  ').TrimEnd()))
        $logLevel = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO' }[$status]
        Write-XsmLog $logLevel (($Columns | ForEach-Object { $v = $row.($_.Property); if ($v -is [array]) { $v = $v -join ', ' }; "$($_.Name)=$v" }) -join ' | ')
    }
}

function Write-XsmSummary {
    <#
    .SYNOPSIS
        Final summary card:

          ╭─ 🎉  Inventory ready ───────────────────────────────────────────────────────╮
            🌐  Partners    3 Microsoft 365 tenants in scope
          ╰──────────────────────────────────────────────────────────────────────────────╯
    .PARAMETER Values
        Ordered list: key = label, value = @(IconName, Text) or plain text.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values, [ValidateSet('Ok', 'Warn', 'Fail')][string]$Status = 'Ok')
    $C = $script:C; $F = $script:Frame; $width = 78
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red }[$Status]
    $icon = $script:Icons[@{ Ok = 'Done'; Warn = 'Warn'; Fail = 'Fail' }[$Status]]
    $head = " $icon  $Title "
    $rest = [Math]::Max(2, $width - 1 - ($head.Length - $icon.Length + $script:IconWidth))
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}{0}{5}{6}{7}" -f $color, $F.TopLeft, $F.Horizontal, $C.Bold, $head, ($C.Reset + $color), ([string]::new($F.Horizontal, $rest) + $F.TopRight), $C.Reset)
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        $rowIcon, $text = if ($value -is [array]) { (Get-XsmIcon $value[0]), $value[1] } else { '   ', $value }
        Write-Host ("    {0}{1}{2,-11}{3} {4}" -f $rowIcon, $C.Dim, $key, $C.Reset, $text)
        Write-XsmLog 'INFO' ("Summary - {0}: {1}" -f $key, $text)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $color, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    Write-Host ''
}
