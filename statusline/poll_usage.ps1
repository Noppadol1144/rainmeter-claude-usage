# Background poller so the widget updates even when you're not actively
# chatting in a Claude Code terminal session.
#
# Calls https://api.anthropic.com/api/oauth/usage using the OAuth token
# Claude Code already stores locally at ~/.claude/.credentials.json --
# the same credential the CLI itself uses. This is a real authenticated
# API call, not scraping and not a bot-detection bypass.
#
# CAVEAT -- read this before relying on it: this endpoint is undocumented
# (community-discovered, not published by Anthropic) and is known to be
# aggressively rate-limited -- a 429 can persist for hours with no
# Retry-After header, per https://github.com/anthropics/claude-code/issues/31637
# It could also change or disappear without notice. This script backs off
# hard on 429 (doubling, capped at 4h) and never overwrites good cached
# data with a failure -- but if it stops working, that's why.
#
# Because of the above, this runs alongside statusline.ps1, not instead of
# it: whenever you're actually chatting in `claude`, statusline.ps1 gives
# you free, reliable, real-time updates with zero API risk. This poller
# only fills the gaps while you're not.
#
# Access tokens also expire if Claude Code hasn't run in a while (they're
# normally refreshed whenever you use `claude`). On a 401, this script
# tries a one-shot automatic fix: run `claude -p` headlessly to force a
# token refresh, then retry once. That does send one tiny real prompt
# (trivial token cost) -- if you'd rather it never do that automatically,
# see the $AutoRefreshOnExpiry switch below.

$ErrorActionPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# EDIT THESE if you move the widget folder.
$StatusFile = Join-Path (Split-Path -Parent $PSScriptRoot) "skin/usage_status.txt"
$StateFile = Join-Path $ScriptDir "poll_state.json"
$DebugFile = Join-Path $ScriptDir "debug_last_response.json"
$CredFile = "$env:USERPROFILE\.claude\.credentials.json"

# Set to $false to disable the automatic `claude -p` refresh-on-401 and
# just report STATUS=EXPIRED instead (no extra API usage, but you have to
# manually run `claude` yourself to fix it).
$AutoRefreshOnExpiry = $true
$RefreshTimeoutSeconds = 30

function Get-AccessToken {
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $cred = Get-Content $CredFile -Raw | ConvertFrom-Json
        return $cred.claudeAiOauth.accessToken
    } catch {
        return $null
    }
}

function Invoke-UsageApi {
    param([string]$Token)
    # Returns @{ Success=bool; StatusCode=int|$null; Data=object|$null; ErrorMessage=string }
    try {
        $resp = Invoke-WebRequest -Uri "https://api.anthropic.com/api/oauth/usage" `
            -Headers @{ "Authorization" = "Bearer $Token"; "anthropic-beta" = "oauth-2025-04-20" } `
            -UseBasicParsing -TimeoutSec 15
        $resp.Content | Set-Content $DebugFile -Encoding utf8  # always keep the last raw response for troubleshooting
        return @{ Success = $true; StatusCode = 200; Data = ($resp.Content | ConvertFrom-Json); ErrorMessage = $null }
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        return @{ Success = $false; StatusCode = $code; Data = $null; ErrorMessage = $_.Exception.Message }
    }
}

function Format-Reset($resetsAt) {
    # This endpoint returns an ISO 8601 string (e.g. "2026-08-10T07:50:00.83+00:00"),
    # unlike statusline.ps1's source which gives a Unix epoch number -- these
    # are two different Anthropic-side data sources with different formats.
    if (-not $resetsAt) { return "unknown" }
    try {
        $resetTime = [DateTimeOffset]::Parse($resetsAt).ToLocalTime()
    } catch {
        return "unknown"
    }
    $span = $resetTime - (Get-Date)
    if ($span.TotalSeconds -le 0) { return "now" }
    if ($span.TotalHours -ge 24) { return "{0}d {1}h" -f [int][Math]::Floor($span.TotalDays), $span.Hours }
    if ($span.TotalHours -ge 1) { return "{0}h {1}m" -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
    return "{0}m" -f [int][Math]::Floor($span.TotalMinutes)
}

function Write-SuccessStatus($data) {
    $fiveH = $null; $fiveHReset = $null
    $sevenD = $null; $sevenDReset = $null
    if ($data.five_hour) { $fiveH = $data.five_hour.utilization; $fiveHReset = $data.five_hour.resets_at }
    if ($data.seven_day) { $sevenD = $data.seven_day.utilization; $sevenDReset = $data.seven_day.resets_at }

    $status = if ($null -eq $fiveH -and $null -eq $sevenD) { "NOMATCH" } else { "OK" }
    $note = if ($status -eq "NOMATCH") { "Got a response but no five_hour/seven_day fields found -- check $DebugFile" } else { "" }

    $fiveHNum = if ($null -ne $fiveH) { "{0:N0}" -f $fiveH } else { "--" }
    $sevenDNum = if ($null -ne $sevenD) { "{0:N0}" -f $sevenD } else { "--" }

    $lines = @(
        "FIVE_H=$fiveHNum"
        "FIVE_H_RESET=$(Format-Reset $fiveHReset)"
        "SEVEN_D=$sevenDNum"
        "SEVEN_D_RESET=$(Format-Reset $sevenDReset)"
        "UPDATED=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "STATUS=$status"
        "NOTE=$note"
    )
    $tmp = "$StatusFile.tmp"
    ($lines -join "`n") | Set-Content -Path $tmp -Encoding utf8 -NoNewline
    Move-Item -Path $tmp -Destination $StatusFile -Force
    Write-Host "Updated: 5h $fiveHNum% | 7d $sevenDNum%"
}

function Write-FailureNote($statusLabel, $noteText) {
    # Preserve last-good FIVE_H/SEVEN_D/reset numbers -- only touch
    # STATUS/NOTE/UPDATED so the widget doesn't flash to 0 on a failure.
    try {
        $prevLines = Get-Content $StatusFile -Raw
        $prevLines = $prevLines -replace '(?m)^STATUS=.*$', "STATUS=$statusLabel"
        $prevLines = $prevLines -replace '(?m)^NOTE=.*$', "NOTE=$noteText"
        $prevLines = $prevLines -replace '(?m)^UPDATED=.*$', "UPDATED=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (last check failed)"
        $prevLines | Set-Content -Path $StatusFile -Encoding utf8 -NoNewline
    } catch {}
}

function Get-TokenExpiry {
    # Unix ms at which the stored access token expires, or $null if the
    # file is missing or unreadable. Used to tell a real refresh from a
    # failed one -- see Try-RefreshToken.
    try {
        if (-not (Test-Path $CredFile)) { return $null }
        $c = Get-Content $CredFile -Raw | ConvertFrom-Json
        return $c.claudeAiOauth.expiresAt
    } catch {
        return $null
    }
}
function Get-ClaudeLauncher {
    # Claude Code is installed differently per machine: a native claude.exe
    # on one, npm shims (claude.cmd / claude.ps1) on another. Start-Process
    # with redirected output cannot launch a shim directly, so resolve what
    # is actually there and pick the right launcher.
    # Returns @{ File = <program>; Args = <array> } or $null.
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.CommandType -eq 'Application' -and $cmd.Source -like '*.exe') {
        return @{ File = $cmd.Source; Args = @('-p', 'ok') }
    }

    $shim = Get-Command claude.cmd -ErrorAction SilentlyContinue
    if ($shim) {
        return @{ File = $env:ComSpec; Args = @('/c', ('"' + $shim.Source + '" -p ok')) }
    }

    if ($cmd -and $cmd.Source -like '*.ps1') {
        return @{ File = (Get-Command powershell.exe).Source
                  Args  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cmd.Source, '-p', 'ok') }
    }

    return $null
}
function Try-RefreshToken {
    # Runs `claude -p` headlessly to force Claude Code to refresh its own
    # access token (this is the same refresh that happens automatically
    # whenever you use `claude` normally). Times out rather than risking a
    # hung background process if something more serious is wrong (e.g. a
    # fully revoked login that needs interactive browser re-auth).
    try {
        $launcher = Get-ClaudeLauncher
        if (-not $launcher) { return $false }
        $proc = Start-Process -FilePath $launcher.File -ArgumentList $launcher.Args `
            -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput "$env:TEMP\claude_widget_refresh_out.txt" `
            -RedirectStandardError "$env:TEMP\claude_widget_refresh_err.txt"
        $finished = $proc.WaitForExit($RefreshTimeoutSeconds * 1000)
        if (-not $finished) {
            try { Stop-Process -Id $proc.Id -Force } catch {}
            return $false
        }

        # Do NOT test $proc.ExitCode here: Start-Process -PassThru gives back
        # a Process object without the process handle, so ExitCode reads as
        # $null even on a clean exit, and the old "$proc.ExitCode -eq 0"
        # reported failure after every successful refresh. Check the token
        # file instead -- a usable token with an expiry in the future is the
        # condition the caller actually needs.
        $expiry = Get-TokenExpiry
        if (-not $expiry) { return $false }
        return ([double]$expiry -gt [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$state = [PSCustomObject]@{ next_allowed = 0; backoff_seconds = 60 }
if (Test-Path $StateFile) {
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {}
}

if ($state.next_allowed -and $nowEpoch -lt $state.next_allowed) {
    # Still backing off from a previous 429 -- skip quietly.
    exit 0
}

$token = Get-AccessToken
if (-not $token) {
    Write-Host "No access token found at $CredFile -- log into Claude Code first (run 'claude')."
    Write-FailureNote "NOTOKEN" "No credentials found -- run 'claude' once and log in."
    exit 1
}

$result = Invoke-UsageApi -Token $token

if (-not $result.Success -and $result.StatusCode -eq 401 -and $AutoRefreshOnExpiry) {
    Write-Host "Got 401 -- attempting automatic token refresh via 'claude -p'..."
    if (Try-RefreshToken) {
        $token = Get-AccessToken
        if ($token) {
            $result = Invoke-UsageApi -Token $token
        }
    } else {
        Write-Host "Auto-refresh didn't complete in time or failed."
    }
}

if ($result.Success) {
    [PSCustomObject]@{ next_allowed = 0; backoff_seconds = 60 } | ConvertTo-Json | Set-Content $StateFile -Encoding utf8
    Write-SuccessStatus $result.Data
    exit 0
}

# Still failed after the retry (if any).
if ($result.StatusCode -eq 429) {
    $newBackoff = [Math]::Min(($state.backoff_seconds * 2), 14400)
    [PSCustomObject]@{ next_allowed = $nowEpoch + $newBackoff; backoff_seconds = $newBackoff } |
        ConvertTo-Json | Set-Content $StateFile -Encoding utf8
    Write-Host "Got 429 -- backing off for $newBackoff seconds."
} elseif ($result.StatusCode -eq 401) {
    Write-Host "Still 401 after refresh attempt -- may need interactive login."
    Write-FailureNote "EXPIRED" "Access token expired and auto-refresh didn't fix it -- run 'claude' yourself (may need to log in again via the browser prompt)."
} else {
    Write-Host "Request failed: $($result.ErrorMessage)"
}
exit 1