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

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default
    )

    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-Warning "A value is required."
    }
}

function Read-OptionalValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default = ""
    )

    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $value = Read-Host $label
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
        if (-not $answer) {
            return $Default
        }
        if ($answer -in @("y", "yes")) {
            return $true
        }
        if ($answer -in @("n", "no")) {
            return $false
        }
        Write-Warning "Enter Y or N."
    }
}

function Convert-DomainToBaseDn {
    param([Parameter(Mandatory = $true)][string]$DomainName)

    $labels = @($DomainName.Trim(".").Split(".") | Where-Object { $_ })
    if ($labels.Count -lt 2) {
        throw "The AD DNS domain must contain at least two labels."
    }
    return ($labels | ForEach-Object { "DC=$_" }) -join ","
}

function Convert-ShortNameToUpn {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$DomainName
    )

    if ($UserName.Contains("@")) {
        return $UserName
    }
    if ($UserName.Contains("\")) {
        $UserName = $UserName.Split("\")[-1]
    }
    return "$UserName@$DomainName"
}

function Set-RestrictedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Directory
    )

    $systemSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null
    )
    $inheritance = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    } else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    $acl = if ($Directory) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else {
        [Security.AccessControl.FileSecurity]::new()
    }

    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-EnvironmentFile {
    param(
        [Parameter(Mandatory = $true)]$Values,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = foreach ($key in $Values.Keys) {
        $value = [string]$Values[$key]
        if ($value -match "[`r`n]") {
            throw "Configuration value $key contains a line break."
        }
        "$key=$value"
    }
    [IO.File]::WriteAllLines(
        $Path,
        [string[]]$lines,
        [Text.UTF8Encoding]::new($false)
    )
    Set-RestrictedAcl -Path $Path
}

function Set-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Values,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Values[$Name] = $Value
    Write-EnvironmentFile -Values $Values -Path $Path
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    try {
        return [bool](Test-NetConnection `
            -ComputerName $ComputerName `
            -Port $Port `
            -InformationLevel Quiet `
            -WarningAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Test-Installation {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$SecretPath,
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Config", "Ldap", "Smtp")]
        [string]$Check,
        [string]$SmtpRecipient
    )

    $arguments = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $LauncherPath,
        "-ConfigPath", $ConfigPath,
        "-SecretPath", $SecretPath,
        "-PythonPath", $PythonPath
    )
    if ($Check -eq "Config") {
        $arguments += "-CheckConfig"
    } elseif ($Check -eq "Ldap") {
        $arguments += "-CheckLdap"
    } else {
        if (-not $SmtpRecipient) {
            throw "SmtpRecipient is required for SMTP validation."
        }
        $arguments += @("-ValidateSmtp", $SmtpRecipient)
    }

    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Check validation failed."
    }
}

function Test-ScheduledTaskIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 300
    )

    $before = (Get-ScheduledTaskInfo -TaskName $Name).LastRunTime
    Start-ScheduledTask -TaskName $Name
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskName $Name
        $info = Get-ScheduledTaskInfo -TaskName $Name
        $completedNewRun = $info.LastRunTime -gt $before -and $task.State -ne "Running"
    } while (-not $completedNewRun -and (Get-Date) -lt $deadline)

    if (-not $completedNewRun) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
        throw "SYSTEM task smoke test timed out; the task was removed."
    }
    if ($info.LastTaskResult -ne 0) {
        $result = $info.LastTaskResult
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
        throw "SYSTEM task smoke test failed with result $result; the task was removed."
    }

    Write-Host "[OK] SYSTEM task smoke test passed with machine-scope DPAPI."
}

if (-not (Test-IsAdministrator)) {
    throw "Run this installer from an elevated PowerShell console."
}

$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installDir = Join-Path $env:ProgramFiles "AD Password Sentinel"
$dataDir = Join-Path $env:ProgramData "AD Password Sentinel"
$reportDir = Join-Path $dataDir "reports"
$configPath = Join-Path $dataDir "config.env"
$secretPath = Join-Path $dataDir "secrets.json"
$launcherPath = Join-Path $installDir "Notify-AdPasswordExpiry.ps1"
$pythonEnginePath = Join-Path $installDir "notify_ad_password_expiry.py"
$credentialScriptPath = Join-Path $installDir "scripts\New-WindowsCredential.ps1"
$taskScriptPath = Join-Path $installDir "scripts\windows_task.ps1"
$venvPythonPath = Join-Path $installDir "venv\Scripts\python.exe"

Write-Host ""
Write-Host "AD Password Sentinel - Windows installation"
Write-Host "Immutable application: $installDir"
Write-Host "Restricted configuration and secrets: $dataDir"
Write-Host ""

$dcFqdn = Read-RequiredValue -Prompt "Domain controller FQDN" -Default "dc01.example.local"
$dcIpFallback = Read-OptionalValue -Prompt "Domain controller IP fallback (optional)"
$domainDefault = if ($dcFqdn -match "^[^.]+\.(.+)$") { $Matches[1] } else { "" }
$domainName = Read-RequiredValue -Prompt "Active Directory DNS domain" -Default $domainDefault
$baseDnDefault = Convert-DomainToBaseDn -DomainName $domainName
$baseDn = Read-RequiredValue -Prompt "LDAP base DN" -Default $baseDnDefault
$bindShortName = Read-RequiredValue `
    -Prompt "AD bind account short username" `
    -Default "svc_ad_password_sentinel"
$bindUpnDefault = Convert-ShortNameToUpn -UserName $bindShortName -DomainName $domainName
$bindUpn = Read-RequiredValue -Prompt "AD bind UPN" -Default $bindUpnDefault

$directoryLabel = Read-RequiredValue -Prompt "Directory label" -Default $domainName
$warningDays = Read-RequiredValue -Prompt "Warning window in days" -Default "14"
$notifyDays = Read-RequiredValue -Prompt "Notification days" -Default "14,7,3,1,0"
$notifyUsers = Read-YesNo -Prompt "Notify individual users after TEST_MODE is disabled?" -Default $false
$allowedDomains = Read-RequiredValue -Prompt "Allowed user email domains" -Default $domainName
$mailFrom = Read-RequiredValue -Prompt "Sender email address"
$techReportTo = Read-RequiredValue -Prompt "Technical report recipient"
$smtpServer = Read-RequiredValue -Prompt "SMTP server FQDN or IP"
$smtpPort = Read-RequiredValue -Prompt "SMTP port" -Default "587"
$smtpSecurity = Read-RequiredValue `
    -Prompt "SMTP security (none, starttls, or ssl)" `
    -Default "starttls"
$smtpSecurity = $smtpSecurity.ToLowerInvariant()
if ($smtpSecurity -notin @("none", "starttls", "ssl")) {
    throw "SMTP security must be none, starttls, or ssl."
}
$smtpAuth = Read-YesNo -Prompt "Authenticate to SMTP?" -Default $false
$smtpUser = ""
if ($smtpAuth) {
    $smtpUser = Read-RequiredValue -Prompt "SMTP username"
}
$startTime = Read-RequiredValue -Prompt "Daily task start time (HH:mm)" -Default "08:00"
if ($startTime -notmatch "^(?:[01]\d|2[0-3]):[0-5]\d$") {
    throw "Task time must use 24-hour HH:mm format."
}

$ldapHost = $dcFqdn
if (-not (Test-TcpPort -ComputerName $dcFqdn -Port 636)) {
    if ($dcIpFallback -and (Test-TcpPort -ComputerName $dcIpFallback -Port 636)) {
        Write-Warning "LDAPS TCP connectivity uses the IP fallback. Certificate name validation may reject it."
        $ldapHost = $dcIpFallback
    } else {
        Write-Warning "TCP port 636 was not reachable. The authenticated LDAPS check will still run."
    }
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $installDir "scripts") -Force | Out-Null
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
Set-RestrictedAcl -Path $dataDir -Directory
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceRoot "Notify-AdPasswordExpiry.ps1") `
    -Destination $launcherPath -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "notify_ad_password_expiry.py") `
    -Destination $pythonEnginePath -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "requirements.txt") `
    -Destination (Join-Path $installDir "requirements.txt") -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\New-WindowsCredential.ps1") `
    -Destination $credentialScriptPath -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\windows_task.ps1") `
    -Destination $taskScriptPath -Force

$bootstrapPython = (Get-Command python.exe -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $venvPythonPath)) {
    Invoke-CheckedCommand `
        -FilePath $bootstrapPython `
        -Arguments @("-m", "venv", (Join-Path $installDir "venv")) `
        -Description "Python virtual environment creation"
}
Invoke-CheckedCommand `
    -FilePath $venvPythonPath `
    -Arguments @(
        "-m", "pip", "install", "--disable-pip-version-check",
        "-r", (Join-Path $installDir "requirements.txt")
    ) `
    -Description "Python dependency installation"

$config = [ordered]@{
    LDAP_MODE = "ldaps"
    LDAP_HOST = $ldapHost
    LDAP_PORT = "636"
    LDAP_TLS_VALIDATE = "true"
    ALLOW_INSECURE_LDAP = "false"
    LDAP_BASE_DN = $baseDn
    LDAP_BIND_USER = $bindUpn
    DIRECTORY_LABEL = $directoryLabel
    WARNING_DAYS = $warningDays
    NOTIFY_DAYS = $notifyDays
    NOTIFY_USERS = $notifyUsers.ToString().ToLowerInvariant()
    USER_MAIL_ALLOWED_DOMAINS = $allowedDomains
    MAIL_FROM = $mailFrom
    TECH_REPORT_TO = $techReportTo
    USER_MAIL_SUBJECT = "Your password will expire soon"
    MAIL_TRANSPORT = "smtp"
    TEST_MODE = "true"
    ALWAYS_SEND_REPORT = "true"
    REPORT_DIR = $reportDir
    REPORT_CSV = "ad-password-expiry-report.csv"
    SMTP_HOST = $smtpServer
    SMTP_PORT = $smtpPort
    SMTP_SECURITY = $smtpSecurity
}
Write-EnvironmentFile -Values $config -Path $configPath

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $credentialScriptPath `
    -CredentialName AdBind `
    -UserName $bindUpn `
    -SecretPath $secretPath
if ($LASTEXITCODE -ne 0) {
    throw "AD bind credential creation failed."
}

if ($smtpAuth) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $credentialScriptPath `
        -CredentialName Smtp `
        -UserName $smtpUser `
        -SecretPath $secretPath
    if ($LASTEXITCODE -ne 0) {
        throw "SMTP credential creation failed."
    }
}

Test-Installation `
    -LauncherPath $launcherPath `
    -ConfigPath $configPath `
    -SecretPath $secretPath `
    -PythonPath $venvPythonPath `
    -Check Config

try {
    Test-Installation `
        -LauncherPath $launcherPath `
        -ConfigPath $configPath `
        -SecretPath $secretPath `
        -PythonPath $venvPythonPath `
        -Check Ldap
} catch {
    Write-Warning $_.Exception.Message
    Write-Warning "LDAPS validation did not complete. LDAP fallback sends credentials without transport encryption."
    if (-not (Read-YesNo -Prompt "Explicitly accept insecure LDAP fallback on port 389?" -Default $false)) {
        throw "Installation stopped before task registration because validation failed."
    }

    $fallbackHost = if ($dcIpFallback) { $dcIpFallback } else { $dcFqdn }
    if (-not (Test-TcpPort -ComputerName $fallbackHost -Port 389)) {
        throw "LDAP fallback endpoint $fallbackHost`:389 is not reachable."
    }
    Set-ConfigValue -Values $config -Name "LDAP_MODE" -Value "ldap" -Path $configPath
    Set-ConfigValue -Values $config -Name "LDAP_HOST" -Value $fallbackHost -Path $configPath
    Set-ConfigValue -Values $config -Name "LDAP_PORT" -Value "389" -Path $configPath
    Set-ConfigValue -Values $config -Name "ALLOW_INSECURE_LDAP" `
        -Value "true" -Path $configPath

    Test-Installation `
        -LauncherPath $launcherPath `
        -ConfigPath $configPath `
        -SecretPath $secretPath `
        -PythonPath $venvPythonPath `
        -Check Ldap
}

Test-Installation `
    -LauncherPath $launcherPath `
    -ConfigPath $configPath `
    -SecretPath $secretPath `
    -PythonPath $venvPythonPath `
    -Check Smtp `
    -SmtpRecipient $techReportTo

Write-Host ""
Write-Host "[OK] Configuration, LDAP bind, and direct SMTP delivery validated."
Write-Host "TEST_MODE remains true."

if (Read-YesNo -Prompt "Register the recommended daily SYSTEM task at $startTime?" -Default $true) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $sourceRoot "scripts\windows_task.ps1") `
        -ScriptPath $launcherPath `
        -ConfigPath $configPath `
        -SecretPath $secretPath `
        -PythonPath $venvPythonPath `
        -TaskName $TaskName `
        -StartTime $startTime
    if ($LASTEXITCODE -ne 0) {
        throw "Scheduled task registration failed."
    }
    Test-ScheduledTaskIdentity -Name $TaskName
    Write-Host "[OK] Scheduled task registered: $TaskName"
} else {
    Write-Host "Task registration skipped. Validated files remain installed."
}

if (Read-YesNo -Prompt "Enable live notifications now?" -Default $false) {
    Set-ConfigValue -Values $config -Name "TEST_MODE" -Value "false" -Path $configPath
    Write-Host "Live notifications enabled."
}
