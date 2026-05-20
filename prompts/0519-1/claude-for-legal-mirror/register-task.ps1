# ============================================================================
# register-task.ps1  —  Install the daily sync as a Windows Scheduled Task
# ----------------------------------------------------------------------------
# Run this ONCE on the VPS (as Administrator) AFTER setup-mirror.ps1.
#
# Creates a task that triggers sync-claude-for-legal.ps1 every day at 02:00
# under the SYSTEM account so it runs even when no user is logged in.
#
# Uninstall:  schtasks /Delete /TN "claude-for-legal-sync" /F
# ============================================================================

$ErrorActionPreference = 'Stop'

$TaskName   = 'claude-for-legal-sync'
$ScriptPath = 'C:\caddy\scripts\sync-claude-for-legal.ps1'
$LogDir     = 'C:\caddy\logs\sync-claude-for-legal'

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] sync script not found at $ScriptPath" -ForegroundColor Red
    Write-Host "        Copy sync-claude-for-legal.ps1 to C:\caddy\scripts\ first."
    exit 1
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}

# Use ScheduledTasks PowerShell module (preferred over schtasks.exe)
$action = New-ScheduledTaskAction `
    -Execute 'PowerShell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -Daily -At 02:00

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 10) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# Remove any prior version
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[register] removed existing task '$TaskName'"
}

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Description 'Daily mirror of CSlawyer1985/claude-for-legal-ZH (02:00).' `
    -Action      $action `
    -Trigger     $trigger `
    -Principal   $principal `
    -Settings    $settings | Out-Null

Write-Host "[register] task '$TaskName' installed. Next run:" -ForegroundColor Green
(Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo).NextRunTime

Write-Host ''
Write-Host 'Verify with:'
Write-Host "  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
Write-Host 'Trigger an immediate dry run:'
Write-Host "  Start-ScheduledTask -TaskName $TaskName"
Write-Host 'Inspect log:'
Write-Host "  Get-Content (Join-Path '$LogDir' (Get-Date -Format 'yyyy-MM').log + '.log') -Tail 50"
