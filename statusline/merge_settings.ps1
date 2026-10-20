# Wires statusline.ps1 into Claude Code's settings.json WITHOUT clobbering
# any other settings you already have there. Backs up the existing file
# first (settings.json.bak) since there's no version control to fall back
# on otherwise.
#
# Run once:
#   cd path\to\claude-usage-widget\statusline
#   .\merge_settings.ps1

$ErrorActionPreference = "Stop"

$settingsPath = "$env:USERPROFILE\.claude\settings.json"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$statuslinePath = (Join-Path $scriptDir "statusline.ps1") -replace '\\', '/'

if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak.$(Get-Date -Format yyyyMMddHHmmss)" -Force
    Write-Host "Backed up existing settings to $settingsPath.bak"
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $dir = Split-Path -Parent $settingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $settings = [PSCustomObject]@{}
    Write-Host "No existing settings.json -- creating a new one."
}

$statusLineValue = [PSCustomObject]@{
    type    = "command"
    command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$statuslinePath`""
}

if ($settings.PSObject.Properties.Name -contains "statusLine") {
    $settings.statusLine = $statusLineValue
} else {
    $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLineValue
}

$settings | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding utf8

Write-Host "Done. statusLine now points to $statuslinePath"
Write-Host "Restart any open Claude Code session for it to take effect."
