[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

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

Write-Host "AD Password Sentinel Docker uninstall"

if (-not (Read-YesNo -Prompt "Are you sure you want to remove the Docker deployment assets?" -Default $false)) {
    throw "Uninstall cancelled."
}

docker compose down | Out-Null

if (Read-YesNo -Prompt "Delete generated Docker config, secrets, certs, reports, and .env?" -Default $false) {
    @("config", "secrets", "certs", "reports", ".env") | ForEach-Object {
        if (Test-Path -LiteralPath $_) {
            Remove-Item -LiteralPath $_ -Recurse -Force
        }
    }
}

Write-Host "Docker uninstall completed."
