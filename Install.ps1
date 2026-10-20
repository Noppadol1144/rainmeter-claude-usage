param([string]$SkinPath, [switch]$StatusLine, [switch]$BackgroundPolling)
$ErrorActionPreference = 'Stop'
if (-not $SkinPath) {
    $config = Join-Path $env:APPDATA 'Rainmeter/Rainmeter.ini'
    if (Test-Path $config) {
        $match = Select-String -Path $config -Pattern '^SkinPath=(.+)$' | Select-Object -First 1
        if ($match) { $SkinPath = [Environment]::ExpandEnvironmentVariables($match.Matches[0].Groups[1].Value.Trim()) }
    }
}
if (-not $SkinPath) { throw 'Specify -SkinPath with your Rainmeter Skins directory.' }
$destination = Join-Path $SkinPath 'ClaudeUsage'
New-Item -ItemType Directory $destination -Force | Out-Null
$ini = Join-Path $destination 'ClaudeUsage.ini'
if (Test-Path $ini) { Copy-Item $ini "$ini.bak.$(Get-Date -Format yyyyMMddHHmmss)" }
$template = Get-Content (Join-Path $PSScriptRoot 'skin/ClaudeUsage/ClaudeUsage.ini') -Raw
$data = (Join-Path $PSScriptRoot 'skin/usage_status.txt').Replace('\','/')
$wrapper = Join-Path $PSScriptRoot 'statusline/run_poll_hidden.vbs'
$poller = Join-Path $PSScriptRoot 'statusline/poll_usage.ps1'
$template = $template -replace '(?m)^StatusFile=.*$', "StatusFile=$data"
$template = $template -replace '(?m)^PollScript=.*$', "PollScript=$($wrapper.Replace('\','/'))"
[IO.File]::WriteAllText($ini, $template)
@"
Set shell = CreateObject("WScript.Shell")
code = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$poller""", 0, True)
WScript.Quit code
"@ | Set-Content $wrapper -Encoding ascii
if (-not (Test-Path $data)) {
    [IO.File]::WriteAllText($data, "FIVE_H=--`nFIVE_H_RESET=unknown`nSEVEN_D=--`nSEVEN_D_RESET=unknown`nUPDATED=never`nSTATUS=NOTSTARTED`nNOTE=Run collector or enable statusLine")
}
if ($StatusLine) { & (Join-Path $PSScriptRoot 'statusline/merge_settings.ps1') }
if ($BackgroundPolling) { & (Join-Path $PSScriptRoot 'statusline/install_poll_task.ps1') }
Write-Host 'Installed. Refresh Rainmeter and load ClaudeUsage.ini. Keep this repository in its current location.'
