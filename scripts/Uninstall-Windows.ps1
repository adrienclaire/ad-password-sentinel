[CmdletBinding()]
param(
    [string]$TaskName = "AD Password Sentinel"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @("y", "yes")) { return $true }
        if ($answer -in @("n", "no")) { return $false }
        Write-Warning "Enter Y or N."
    }
}

if (-not (Test-IsAdministrator)) {
    throw "Run this uninstaller from an elevated PowerShell console."
}

$InstallDir = Join-Path $env:ProgramFiles "AD Password Sentinel"
$DataDir = Join-Path $env:ProgramData "AD Password Sentinel"

Write-Host ""
Write-Host "AD Password Sentinel - Windows uninstall"
Write-Host ""

if (-not (Read-YesNo -Prompt "Are you sure you want to uninstall AD Password Sentinel from this computer?" -Default $false)) {
    throw "Uninstall cancelled."
}

$RemoveData = Read-YesNo -Prompt "Remove configuration, secrets, and reports from ProgramData as well?" -Default $false

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

if ($RemoveData -and (Test-Path -LiteralPath $DataDir)) {
    Remove-Item -LiteralPath $DataDir -Recurse -Force
}

Write-Host "Uninstall completed."
