param(
    [string]$UserName = "svc_ad_password_sentinel@example.local",
    [string]$CredentialPath = "C:\ADPasswordSentinel\bind-credential.xml"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$directory = Split-Path -Parent $CredentialPath
New-Item -ItemType Directory -Path $directory -Force | Out-Null

$credential = Get-Credential -UserName $UserName
$credential | Export-Clixml -Path $CredentialPath

Write-Host "Credential saved to $CredentialPath"
Write-Host "This file is protected with Windows DPAPI for the current user or machine context."
