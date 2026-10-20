# Registers a Windows Task Scheduler task that runs poll_usage.ps1 every
# 15 minutes, so the widget updates even when you're not actively chatting
# in a Claude Code terminal. 15 minutes is deliberately conservative --
# the endpoint it calls is known to rate-limit hard on frequent polling
# (see the caveat at the top of poll_usage.ps1).
#
#   cd path\to\claude-usage-widget\statusline
#   .\install_poll_task.ps1
#
# Remove later with:
#   Unregister-ScheduledTask -TaskName "ClaudeUsagePoll" -Confirm:$false

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $scriptDir "poll_usage.ps1"
$vbsPath = Join-Path $scriptDir "run_poll_hidden.vbs"

# The task runs while you are logged on, so calling powershell.exe directly
# pops a console window into view every 15 minutes. wscript.exe running the
# wrapper below starts the same command with window style 0 (hidden), so
# nothing flashes. The wrapper is rewritten here rather than shipped fixed,
# so it always points at THIS folder's poll_usage.ps1 even if the widget is
# installed somewhere other than C:\Scripts\claude-usage-widget.
#
# Trade-off: Task Scheduler then records wscript's exit code, which is 0
# whatever poll_usage.ps1 does. Judge whether a poll actually worked by the
# UPDATED line in usage_status.txt or by debug_last_response.json, not by
# LastTaskResult.
@"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$scriptPath""", 0, True
"@ | Set-Content -Path $vbsPath -Encoding ascii

$action = New-ScheduledTaskAction -Execute "wscript.exe" `
    -Argument "`"$vbsPath`"" `
    -WorkingDirectory $scriptDir

# RepetitionDuration: [TimeSpan]::MaxValue serialises to P99999999DT23H59M59S,
# which some machines' Task Scheduler rejects outright with
# "The task XML contains a value which is incorrectly formatted or out of
# range" (HRESULT 0x80041318). A large but finite duration registers
# everywhere; 10 years of 15-minute repeats is effectively forever here.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName "ClaudeUsagePoll" `
    -Action $action -Trigger $trigger -Settings $settings `
    -Description "Background refresh for the Claude usage widget (every 15 min)." `
    -Force

Write-Host "Scheduled task 'ClaudeUsagePoll' installed, runs every 15 minutes (hidden window)."
Write-Host "Test it once now: Start-ScheduledTask -TaskName 'ClaudeUsagePoll'"