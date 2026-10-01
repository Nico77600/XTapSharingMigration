#Requires -Version 7.4

<#
.SYNOPSIS
    Copies the files needed to run X-TAP Sharing Migration into a separate folder, ready to be zipped.

.DESCRIPTION
    The package contains what Invoke-XTapSharingMigration.ps1 needs at run time, the HTML guide, the README,
    the changelog and the licence:
        Invoke-XTapSharingMigration.ps1, XTapSharingMigration.psd1, XTapSharingMigration.psm1,
        src\, templates\, config\, docs\XTapSharingMigration-Guide.html, README.md, CHANGELOG.md, LICENSE
    It never copies output\, logs\ or the tests: no tenant data is in the package.

    The configuration file is copied with the tenant values emptied (TenantId, Organization, ExchangeAdmin,
    EntraAdmin, GraphClientId, AppId, CertificateThumbprint) and the Partners and Groups sections reset to
    the delivered examples. The script then checks that none of the emptied values appears in the package.

.PARAMETER Destination
    Package folder. Default: package\XTapSharingMigration-<version>, next to the tool folder.

.PARAMETER Force
    Replace the destination folder if it already contains a package. A folder with an output\ sub-folder
    (a package that has been run) is never replaced.

.EXAMPLE
    .\tools\New-XsmPackage.ps1

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Import-PowerShellDataFile (Join-Path $root 'XTapSharingMigration.psd1')).ModuleVersion
if (-not $Destination) { $Destination = Join-Path (Split-Path $root -Parent) "package\XTapSharingMigration-$version" }
$Destination = [IO.Path]::GetFullPath($Destination, (Get-Location).Path).TrimEnd('\')

$rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (($Destination + '\').StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or $rootPrefix.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "The destination must be outside the tool folder: $Destination"
}
if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) { throw "The destination already exists: $Destination. Use -Force to replace it." }
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Invoke-XTapSharingMigration.ps1'))) { throw "The destination is not an X-TAP Sharing Migration package, it is not replaced: $Destination" }
    if (Test-Path -LiteralPath (Join-Path $Destination 'output')) { throw "The destination contains an output folder (tenant data), it is not replaced: $Destination" }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

# ---- Files needed at run time ---------------------------------------------------------------------------
$files = [Collections.Generic.List[string]]::new()
foreach ($f in 'Invoke-XTapSharingMigration.ps1', 'XTapSharingMigration.psd1', 'XTapSharingMigration.psm1', 'README.md', 'CHANGELOG.md', 'LICENSE',
    'templates\Report.template.html', 'docs\XTapSharingMigration-Guide.html') { $files.Add($f) }
Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | ForEach-Object { $files.Add("src\$($_.Name)") }

foreach ($f in $files) {
    $source = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing file in the tool folder: $f" }
    $target = Join-Path $Destination $f
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $source -Destination $target
}

# ---- Configuration with the tenant values emptied -------------------------------------------------------
$configRelative = 'config\XTapSharingMigration.config.psd1'
$config = [IO.File]::ReadAllText((Join-Path $root $configRelative))
$emptied = [Collections.Generic.List[string]]::new()
foreach ($key in 'TenantId', 'Organization', 'ExchangeAdmin', 'EntraAdmin', 'GraphClientId', 'AppId', 'CertificateThumbprint') {
    $pattern = "(?m)^(\s*$key\s*=\s*)'([^']*)'"
    $found = [regex]::Matches($config, $pattern)
    if ($found.Count -ne 1) { throw "The key $key must appear exactly once in $configRelative (found $($found.Count))." }
    if ($found[0].Groups[2].Value) { $emptied.Add($found[0].Groups[2].Value) }
    $config = [regex]::Replace($config, $pattern, '$1''''')
}
# Partners and Groups: only commented examples are allowed in the delivered file.
foreach ($section in 'Partners', 'Groups') {
    $block = [regex]::Match($config, "(?ms)^\s*$section = @[\(\{](.*?)^\s*[\)\}]\s*$")
    if (-not $block.Success) { throw "Section $section not found in $configRelative." }
    $active = @($block.Groups[1].Value -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    if ($active.Count) { throw "Section $section of $configRelative contains active entries (only commented examples may be delivered): $($active[0].Trim())" }
}
$configTarget = Join-Path $Destination $configRelative
[void][IO.Directory]::CreateDirectory((Split-Path $configTarget -Parent))
[IO.File]::WriteAllText($configTarget, $config, [Text.UTF8Encoding]::new($true))
$files.Add($configRelative)

# ---- Checks ---------------------------------------------------------------------------------------------
$problems = [Collections.Generic.List[string]]::new()
foreach ($name in 'output', 'logs', 'tests', 'lab') {
    if (Test-Path -LiteralPath (Join-Path $Destination $name)) { $problems.Add("Folder $name\ must not be in the package.") }
}
$textFiles = Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object Extension -in '.ps1', '.psm1', '.psd1', '.html', '.md', ''
foreach ($value in $emptied) {
    foreach ($file in $textFiles) {
        if ([IO.File]::ReadAllText($file.FullName).IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $problems.Add("A tenant value of the configuration appears in $($file.FullName.Substring($Destination.Length + 1)).")
        }
    }
}
if ($problems.Count) { throw ("Package not valid ($Destination):`n - " + ($problems -join "`n - ")) }

$all = Get-ChildItem -LiteralPath $Destination -Recurse -File
Write-Host ''
Write-Host "  X-TAP Sharing Migration $version - package ready" -ForegroundColor Green
Write-Host "  Folder   : $Destination"
Write-Host ("  Content  : {0} files, {1:N1} MB" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))
Write-Host "  Config   : tenant values emptied ($($emptied.Count)) - fill in Tenant and Authentication (guide, chapter 7)"
Write-Host ''
$all | Sort-Object FullName | ForEach-Object { '    {0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring($Destination.Length + 1) }
