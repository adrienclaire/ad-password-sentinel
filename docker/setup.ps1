[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

function Read-Required {
    param([string]$Prompt)
    do {
        $Value = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($Value))
    return $Value.Trim()
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $Value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return $Value.Trim()
}

$DcFqdn = Read-Required "Domain controller FQDN"
$DcIp = Read-Required "Domain controller IP fallback"
$Labels = $DcFqdn.Trim(".").Split(".", [System.StringSplitOptions]::RemoveEmptyEntries)
if ($Labels.Count -lt 2) {
    throw "DC FQDN must include a host and domain, for example dc01.example.com."
}

$DomainLabels = $Labels[1..($Labels.Count - 1)]
$Domain = $DomainLabels -join "."
$BaseDn = ($DomainLabels | ForEach-Object { "DC=$_" }) -join ","
$BindAccount = Read-Default "LDAP bind account name or UPN" "svc_ad_password_sentinel"
$BindUpn = if ($BindAccount.Contains("@")) { $BindAccount } else { "$BindAccount@$Domain" }

$LdapSecure = Read-Host "LDAP bind password" -AsSecureString
$LdapPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($LdapSecure)
try {
    $LdapPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($LdapPointer)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($LdapPointer)
}
if ([string]::IsNullOrEmpty($LdapPassword)) { throw "LDAP password must not be empty." }

$SmtpHost = Read-Required "Direct SMTP relay host"
$SmtpPort = Read-Default "SMTP relay port" "587"
$SmtpSecurity = Read-Default "SMTP security (starttls, ssl, none)" "starttls"
$SmtpUsername = Read-Host "SMTP username (leave blank for relay without authentication)"
$SmtpPassword = ""
if (-not [string]::IsNullOrWhiteSpace($SmtpUsername)) {
    if ($SmtpSecurity -eq "none") {
        throw "SMTP authentication requires starttls or ssl."
    }
    $SmtpSecure = Read-Host "SMTP password" -AsSecureString
    $SmtpPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SmtpSecure)
    try {
        $SmtpPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($SmtpPointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($SmtpPointer)
    }
}
$MailFrom = Read-Required "Sender email address"
$TechReportTo = Read-Required "Technical report recipient"
$Timezone = Read-Default "Container timezone" "Europe/Paris"
$CaSource = Read-Host "CA certificate path for LDAPS (leave blank when publicly trusted)"

@("config", "secrets", "certs", "reports") | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

[IO.File]::WriteAllText((Join-Path $RootDir "secrets\ldap-password"), "$LdapPassword`n")
[IO.File]::WriteAllText((Join-Path $RootDir "secrets\smtp-password"), "$SmtpPassword`n")

$CaTarget = Join-Path $RootDir "certs\ca.crt"
if (-not [string]::IsNullOrWhiteSpace($CaSource)) {
    if (-not (Test-Path -LiteralPath $CaSource -PathType Leaf)) {
        throw "CA certificate not found: $CaSource"
    }
    Copy-Item -LiteralPath $CaSource -Destination $CaTarget -Force
    $CaConfigLine = "LDAP_CA_FILE=/run/certs/ad-password-sentinel-ca.crt"
} else {
    [IO.File]::WriteAllText($CaTarget, "")
    $CaConfigLine = ""
}

$Config = @"
TEST_MODE=true
LDAP_MODE=ldaps
LDAP_HOST=$DcFqdn
LDAP_PORT=636
LDAP_BASE_DN=$BaseDn
LDAP_BIND_USER=$BindUpn
LDAP_PASSWORD_FILE=/run/secrets/ldap-password
LDAP_TLS_VALIDATE=true
$CaConfigLine
DIRECTORY_LABEL=$Domain Active Directory
WARNING_DAYS=14
NOTIFY_DAYS=14,7,3,1,0
NOTIFY_USERS=false
USER_MAIL_ALLOWED_DOMAINS=$Domain
MAIL_TRANSPORT=smtp
SMTP_HOST=$SmtpHost
SMTP_PORT=$SmtpPort
SMTP_SECURITY=$SmtpSecurity
SMTP_USER=$SmtpUsername
SMTP_PASSWORD_FILE=/run/secrets/smtp-password
MAIL_FROM=$MailFrom
TECH_REPORT_TO=$TechReportTo
USER_MAIL_SUBJECT=Your password will expire soon
ALWAYS_SEND_REPORT=true
REPORT_DIR=/var/log/ad-password-sentinel
REPORT_CSV=ad-password-expiry-report.csv
"@
[IO.File]::WriteAllText((Join-Path $RootDir "config\config.env"), $Config)

$ComposeEnv = @"
TZ=$Timezone
LDAP_HOST=$DcFqdn
LDAP_IP=$DcIp
CONTAINER_UID=10001
CONTAINER_GID=10001
HOST_CONFIG_FILE=./config/config.env
HOST_LDAP_SECRET_FILE=./secrets/ldap-password
HOST_SMTP_SECRET_FILE=./secrets/smtp-password
HOST_CA_FILE=./certs/ca.crt
HOST_REPORTS_DIR=./reports
"@
[IO.File]::WriteAllText((Join-Path $RootDir ".env"), $ComposeEnv)

if ($env:OS -eq "Windows_NT") {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    @("config", "secrets", "certs") |
        ForEach-Object {
            & icacls $_ /inheritance:r /grant:r "${Identity}:(OI)(CI)(F)" "SYSTEM:(OI)(CI)(F)" "Administrators:(OI)(CI)(F)" | Out-Null
        }
    @(".env", "config\config.env", "secrets\ldap-password", "secrets\smtp-password", "certs\ca.crt") |
        ForEach-Object {
            & icacls $_ /inheritance:r /grant:r "${Identity}:(F)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
        }
}

$ConfigAbs = (Resolve-Path (Join-Path $RootDir "config\config.env")).Path
$LdapSecretAbs = (Resolve-Path (Join-Path $RootDir "secrets\ldap-password")).Path
$SmtpSecretAbs = (Resolve-Path (Join-Path $RootDir "secrets\smtp-password")).Path
$CaCertAbs = (Resolve-Path (Join-Path $RootDir "certs\ca.crt")).Path
$ReportsAbs = (Resolve-Path (Join-Path $RootDir "reports")).Path

Write-Host ""
Write-Host "Secure Docker configuration created with TEST_MODE=true."
Write-Host "DNS fallback: Compose maps $DcFqdn to $DcIp inside the container."
if (-not [string]::IsNullOrWhiteSpace($CaSource)) {
    Write-Host "CA certificate: mounted read-only at /run/certs/ad-password-sentinel-ca.crt."
} else {
    Write-Host "CA certificate: no custom certificate selected; certs/ca.crt is an empty placeholder."
}
Write-Host "Configuration, LDAP/SMTP secrets, and CA mounts are read-only; reports/ is writable."
Write-Host ""

docker compose build
if ($LASTEXITCODE -ne 0) { throw "docker compose build failed." }
docker compose run --rm ad-password-sentinel validate
if ($LASTEXITCODE -ne 0) { throw "Configuration validation failed." }
docker compose run --rm ad-password-sentinel check-ldap
if ($LASTEXITCODE -ne 0) { throw "LDAP validation failed." }

Write-Host ""
Write-Host "Validation completed. TEST_MODE remains true."
$OfferSchedule = Read-Host "Show the recommended Windows host scheduler command? [y/N]"
if ($OfferSchedule -match "^[Yy]$") {
    $DockerArgs = @(
        "run", "--rm", "--read-only",
        "--user", "10001:10001",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges:true",
        "--add-host", "$DcFqdn`:$DcIp",
        "-e", "TZ=$Timezone",
        "-v", "$ConfigAbs`:/etc/ad-password-sentinel/config.env:ro",
        "-v", "$LdapSecretAbs`:/run/secrets/ldap-password:ro",
        "-v", "$SmtpSecretAbs`:/run/secrets/smtp-password:ro",
        "-v", "$CaCertAbs`:/run/certs/ad-password-sentinel-ca.crt:ro",
        "-v", "$ReportsAbs`:/var/log/ad-password-sentinel:rw",
        "ad-password-sentinel:local",
        "run"
    ) -join " "
    Write-Host "schtasks /Create /SC DAILY /ST 08:00 /TN `"AD Password Sentinel`" /TR `"docker $DockerArgs`""
}
