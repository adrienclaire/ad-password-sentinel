param(
    [string]$ConfigPath = "C:\ADPasswordSentinel\config.json",
    [switch]$CheckConfig,
    [switch]$CheckLdap,
    [string]$SendTestMail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Config {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-RequiredConfig {
    param($Config)

    $required = @(
        "AdServer",
        "SearchBase",
        "BindUser",
        "BindPassword",
        "MailFrom",
        "TechReportTo",
        "SmtpServer"
    )

    foreach ($key in $required) {
        if (-not $Config.PSObject.Properties.Name.Contains($key) -or [string]::IsNullOrWhiteSpace($Config.$key)) {
            throw "Missing required config value: $key"
        }
    }
}

function New-Credential {
    param($Config)

    $securePassword = ConvertTo-SecureString $Config.BindPassword -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential($Config.BindUser, $securePassword)
}

function Get-ExpiringAdUsers {
    param($Config)

    Import-Module ActiveDirectory

    $warningDays = if ($Config.WarningDays) { [int]$Config.WarningDays } else { 14 }
    $now = Get-Date
    $credential = New-Credential -Config $Config

    Get-ADUser `
        -Server $Config.AdServer `
        -Credential $credential `
        -SearchBase $Config.SearchBase `
        -LDAPFilter "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(!(userAccountControl:1.2.840.113556.1.4.803:=65536)))" `
        -Properties DisplayName,mail,UserPrincipalName,msDS-UserPasswordExpiryTimeComputed |
        ForEach-Object {
            $rawExpiry = $_."msDS-UserPasswordExpiryTimeComputed"

            if (-not $rawExpiry -or $rawExpiry -eq 9223372036854775807) {
                return
            }

            $expiry = [DateTime]::FromFileTimeUtc([int64]$rawExpiry)
            $daysLeft = [int]($expiry.Date - $now.Date).TotalDays

            if ($daysLeft -lt 0 -or $daysLeft -le $warningDays) {
                [PSCustomObject]@{
                    SamAccountName = $_.SamAccountName
                    DisplayName = $_.DisplayName
                    Mail = $_.mail
                    UserPrincipalName = $_.UserPrincipalName
                    ExpiryDate = $expiry
                    DaysLeft = $daysLeft
                    Status = if ($daysLeft -lt 0) { "EXPIRED" } else { "EXPIRING_SOON" }
                }
            }
        } | Sort-Object DaysLeft, SamAccountName
}

function Send-NotificationMail {
    param(
        $Config,
        [string]$To,
        [string]$Subject,
        [string]$Body
    )

    if ($Config.TestMode -eq $true) {
        Write-Host "TEST MODE: would send mail to $To"
        Write-Host "Subject: $Subject"
        Write-Host $Body
        return
    }

    Send-MailMessage `
        -SmtpServer $Config.SmtpServer `
        -Port $(if ($Config.SmtpPort) { [int]$Config.SmtpPort } else { 25 }) `
        -From $Config.MailFrom `
        -To $To `
        -Subject $Subject `
        -Body $Body
}

$config = Read-Config -Path $ConfigPath
Test-RequiredConfig -Config $config

if ($CheckConfig) {
    Write-Host "[OK] Configuration is valid."
    exit 0
}

if ($CheckLdap) {
    $null = Get-ExpiringAdUsers -Config $config | Select-Object -First 1
    Write-Host "[OK] LDAP/AD query succeeded."
    exit 0
}

if ($SendTestMail) {
    Send-NotificationMail -Config $config -To $SendTestMail -Subject "[AD Password Sentinel] Test email" -Body "AD Password Sentinel test email."
    Write-Host "[OK] Test email processed for $SendTestMail."
    exit 0
}

$results = @(Get-ExpiringAdUsers -Config $config)
$reportDir = if ($config.ReportDir) { $config.ReportDir } else { "C:\ProgramData\ADPasswordSentinel" }
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

$csvPath = Join-Path $reportDir "ad-password-expiry-report.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$body = @(
    "AD Password Sentinel - password expiration report",
    "",
    "Accounts found: $($results.Count)",
    "CSV local: $csvPath"
) -join "`r`n"

if ($results.Count -gt 0 -or $config.AlwaysSendReport -eq $true) {
    Send-NotificationMail -Config $config -To $config.TechReportTo -Subject "[AD Password Sentinel] Password expiration report - $($results.Count) account(s)" -Body $body
}
