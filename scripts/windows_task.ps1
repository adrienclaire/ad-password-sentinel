param(
    [string]$ScriptPath = (Join-Path $env:ProgramFiles "AD Password Sentinel\Notify-AdPasswordExpiry.ps1"),
    [string]$ConfigPath = (Join-Path $env:ProgramData "AD Password Sentinel\config.env"),
    [string]$SecretPath = (Join-Path $env:ProgramData "AD Password Sentinel\secrets.json"),
    [string]$PythonPath = (Join-Path $env:ProgramFiles "AD Password Sentinel\venv\Scripts\python.exe"),
    [string]$TaskName = "AD Password Sentinel",
    [string]$StartTime = "08:00"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($path in @($ScriptPath, $ConfigPath, $SecretPath, $PythonPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Cannot register task because a required file is missing: $path"
    }
}

if ($StartTime -notmatch "^(?:[01]\d|2[0-3]):[0-5]\d$") {
    throw "StartTime must use 24-hour HH:mm format."
}

$actionArguments = @(
    "-NoProfile"
    "-NonInteractive"
    "-ExecutionPolicy Bypass"
    "-File `"$ScriptPath`""
    "-ConfigPath `"$ConfigPath`""
    "-SecretPath `"$SecretPath`""
    "-PythonPath `"$PythonPath`""
) -join " "

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument $actionArguments

$Trigger = New-ScheduledTaskTrigger -Daily -At $StartTime
$Principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $Principal `
    -Settings $Settings `
    -Description "Runs AD Password Sentinel with the SYSTEM machine-DPAPI identity." `
    -Force
