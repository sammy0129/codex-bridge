param(
    [string]$Repository = (Split-Path $PSScriptRoot -Parent),
    [string]$DataDir = (Join-Path $env:USERPROFILE '.codex-android-bridge')
)
$ErrorActionPreference = 'Stop'
$taskName = 'CodexAndroidBridge'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Task already exists. Inspect or remove it explicitly before registering a replacement.' }
$Repository = (Resolve-Path -LiteralPath $Repository).Path
$runner = Join-Path $Repository 'scripts/run-bridge.ps1'
$identity = "$env:USERDOMAIN\$env:USERNAME"
$arguments = "-NoProfile -WindowStyle Hidden -File `"$runner`" -Repository `"$Repository`" -DataDir `"$DataDir`""
$action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments -WorkingDirectory $Repository
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
Write-Output 'Registered current-user logon task. It does not request elevation or change firewall rules.'
