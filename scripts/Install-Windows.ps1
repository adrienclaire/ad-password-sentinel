param(
    [string]$InstallDir = "C:\ADPasswordSentinel",
    [string]$TaskName = "AD Password Sentinel",
    [string]$StartTime = "08:00"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptPath = Join-Path $InstallDir "Notify-AdPasswordExpiry.ps1"
$configPath = Join-Path $InstallDir "config.json"
$credentialPath = Join-Path $InstallDir "bind-credential.xml"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceRoot "Notify-AdPasswordExpiry.ps1") -Destination $scriptPath -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "config.windows.example.json") -Destination $configPath -Force

Write-Host "Files copied to $InstallDir"
Write-Host "Create the AD bind credential next."

& (Join-Path $sourceRoot "scripts\New-WindowsCredential.ps1") `
    -UserName "svc_ad_password_sentinel@example.local" `
    -CredentialPath $credentialPath

Write-Host "Edit $configPath before enabling the scheduled task."

& (Join-Path $sourceRoot "scripts\windows_task.ps1") `
    -ScriptPath $scriptPath `
    -ConfigPath $configPath `
    -TaskName $TaskName `
    -StartTime $StartTime

Write-Host "Scheduled task registered: $TaskName"
