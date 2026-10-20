# Claude Code statusLine script.
#
# Two jobs:
#   1. Print a compact line -- this is what Claude Code shows at the
#      bottom of your terminal (5h/7d rate-limit % right where you work).
#   2. Write those same numbers to usage_status.txt for the desktop
#      widget to pick up.
#
# Claude Code invokes this command itself on every status line refresh
# while a session is open, piping session JSON (including rate_limits)
# on stdin. This is the officially documented mechanism:
# https://code.claude.com/docs/en/statusline
#
# No scraping, no browser, no undocumented endpoint -- this is the exact
# 5-hour/7-day usage percentage Claude Code already knows about your
# Pro/Max plan, just read off stdin instead of an API call.
#
# Setup: see ..\README.md for the settings.json entry that wires this up.

$ErrorActionPreference = "SilentlyContinue"

# -----------------------------------------------------------------------
# EDIT THIS if you move the widget folder.
# -----------------------------------------------------------------------
$StatusFile = Join-Path (Split-Path -Parent $PSScriptRoot) "skin/usage_status.txt"

# Don't hammer the disk -- statusline refreshes can fire multiple times a
# second while Claude Code is streaming a response. Skip the file write
# (but still print the terminal status line every time) if we wrote less
# than this many seconds ago.
$ThrottleSeconds = 5

$raw = [Console]::In.ReadToEnd()
$data = $null
try { $data = $raw | ConvertFrom-Json } catch {}

$model = "Claude"
if ($data -and $data.model -and $data.model.display_name) { $model = $data.model.display_name }

$fiveH = $null; $fiveHReset = $null
$sevenD = $null; $sevenDReset = $null
if ($data -and $data.rate_limits) {
    if ($data.rate_limits.five_hour) {
        $fiveH = $data.rate_limits.five_hour.used_percentage
        $fiveHReset = $data.rate_limits.five_hour.resets_at
    }
    if ($data.rate_limits.seven_day) {
        $sevenD = $data.rate_limits.seven_day.used_percentage
        $sevenDReset = $data.rate_limits.seven_day.resets_at
    }
}

function Format-Reset($epoch) {
    if (-not $epoch) { return "unknown" }
    $resetTime = [DateTimeOffset]::FromUnixTimeSeconds([int64]$epoch).ToLocalTime()
    $span = $resetTime - (Get-Date)
    if ($span.TotalSeconds -le 0) { return "now" }
    if ($span.TotalHours -ge 24) { return "{0}d {1}h" -f [int][Math]::Floor($span.TotalDays), $span.Hours }
    if ($span.TotalHours -ge 1) { return "{0}h {1}m" -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
    return "{0}m" -f [int][Math]::Floor($span.TotalMinutes)
}

$fiveHDisplay = if ($null -ne $fiveH) { "{0:N0}%" -f $fiveH } else { "--" }
$sevenDDisplay = if ($null -ne $sevenD) { "{0:N0}%" -f $sevenD } else { "--" }
# Bare numbers (no "%") for the widget -- Rainmeter's Bar meter needs a
# plain number to size the fill, and the skin adds "%" itself for display.
$fiveHNum = if ($null -ne $fiveH) { "{0:N0}" -f $fiveH } else { "--" }
$sevenDNum = if ($null -ne $sevenD) { "{0:N0}" -f $sevenD } else { "--" }

# 1) This is what actually shows at the bottom of the Claude Code terminal.
Write-Output "[$model] 5h $fiveHDisplay | 7d $sevenDDisplay"

# 2) Feed the desktop widget (throttled).
$shouldWrite = $true
if (Test-Path $StatusFile) {
    $age = (Get-Date) - (Get-Item $StatusFile).LastWriteTime
    if ($age.TotalSeconds -lt $ThrottleSeconds) { $shouldWrite = $false }
}

if ($shouldWrite) {
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $status = if ($null -ne $fiveH -or $null -ne $sevenD) { "OK" } else { "NODATA" }
    $note = if ($status -eq "NODATA") {
        "rate_limits not present yet -- send at least one message in a Claude Code session, this only appears after the first API response"
    } else { "" }

    # No rate_limits on this refresh (normal before the first response in a
    # session): keep whatever numbers are already in the file and touch only
    # STATUS/NOTE/UPDATED -- same policy poll_usage.ps1 uses on a failed
    # check, so a fresh session no longer blanks out good figures.
    $payload = $null
    if ($status -eq "NODATA" -and (Test-Path $StatusFile)) {
        try {
            $prev = Get-Content $StatusFile -Raw
            if ($prev -match '(?m)^FIVE_H=') {
                $prev = $prev -replace '(?m)^STATUS=.*$', "STATUS=$status"
                $prev = $prev -replace '(?m)^NOTE=.*$', "NOTE=$note"
                $prev = $prev -replace '(?m)^UPDATED=.*$', "UPDATED=$now (kept previous figures)"
                $payload = $prev
            }
        } catch {}
    }

    if ($null -eq $payload) {
        $lines = @(
            "FIVE_H=$fiveHNum"
            "FIVE_H_RESET=$(Format-Reset $fiveHReset)"
            "SEVEN_D=$sevenDNum"
            "SEVEN_D_RESET=$(Format-Reset $sevenDReset)"
            "UPDATED=$now"
            "STATUS=$status"
            "NOTE=$note"
        )
        $payload = ($lines -join "`n")
    }

    try {
        $dir = Split-Path -Parent $StatusFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmpFile = "$StatusFile.tmp"
        $payload | Set-Content -Path $tmpFile -Encoding utf8 -NoNewline
        Move-Item -Path $tmpFile -Destination $StatusFile -Force
    } catch {}
}
