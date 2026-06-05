param(
    [string]$ScriptPath = "C:\ADPasswordSentinel\Notify-AdPasswordExpiry.ps1",
    [string]$ConfigPath = "C:\ADPasswordSentinel\config.json",
    [string]$TaskName = "AD Password Sentinel",
    [string]$StartTime = "08:00"
)

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""

$Trigger = New-ScheduledTaskTrigger -Daily -At $StartTime
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $Principal `
    -Force
