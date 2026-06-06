param(
    [string]$ConfigPath = (Join-Path $env:ProgramData "AD Password Sentinel\config.env"),
    [string]$SecretPath = (Join-Path $env:ProgramData "AD Password Sentinel\secrets.json"),
    [string]$PythonPath = (Join-Path $env:ProgramFiles "AD Password Sentinel\venv\Scripts\python.exe"),
    [switch]$CheckConfig,
    [switch]$CheckLdap,
    [string]$SendTestMail,
    [string]$ValidateSmtp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-EnvironmentFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
            continue
        }

        $parts = $trimmed.Split(@("="), 2, [StringSplitOptions]::None)
        $values[$parts[0].Trim()] = [Environment]::ExpandEnvironmentVariables(
            $parts[1].Trim().Trim('"').Trim("'")
        )
    }
    return $values
}

function Set-RestrictedAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $systemSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null
    )
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Unprotect-MachineString {
    param([Parameter(Mandatory = $true)][string]$ProtectedValue)

    $protectedBytes = [Convert]::FromBase64String($ProtectedValue)
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    try {
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Write-RestrictedText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
    Set-RestrictedAcl -Path $Path
}

if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    throw "Machine secret file not found: $SecretPath"
}
$secrets = Get-Content -LiteralPath $SecretPath -Raw | ConvertFrom-Json
if (-not $secrets.PSObject.Properties.Name.Contains("AdBind")) {
    throw "The machine secret file does not contain an AdBind credential."
}

$enginePath = Join-Path $PSScriptRoot "notify_ad_password_expiry.py"
foreach ($path in @($PythonPath, $enginePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required runtime file not found: $path"
    }
}

$runtimeId = [Guid]::NewGuid().ToString("N")
$runtimeDirectory = Split-Path -Parent $ConfigPath
$runtimeConfigPath = Join-Path $runtimeDirectory ".runtime-$runtimeId.env"
$ldapPasswordPath = Join-Path $runtimeDirectory ".ldap-$runtimeId.secret"
$smtpPasswordPath = Join-Path $runtimeDirectory ".smtp-$runtimeId.secret"
$temporaryPaths = @($runtimeConfigPath, $ldapPasswordPath, $smtpPasswordPath)

try {
    $runtimeConfig = Read-EnvironmentFile -Path $ConfigPath
    $runtimeConfig["MAIL_TRANSPORT"] = "smtp"

    Write-RestrictedText `
        -Path $ldapPasswordPath `
        -Value (Unprotect-MachineString -ProtectedValue $secrets.AdBind.Password)
    $runtimeConfig["LDAP_PASSWORD_FILE"] = $ldapPasswordPath

    if ($secrets.PSObject.Properties.Name.Contains("Smtp")) {
        Write-RestrictedText `
            -Path $smtpPasswordPath `
            -Value (Unprotect-MachineString -ProtectedValue $secrets.Smtp.Password)
        $runtimeConfig["SMTP_USER"] = $secrets.Smtp.UserName
        $runtimeConfig["SMTP_PASSWORD_FILE"] = $smtpPasswordPath
    }

    if ($ValidateSmtp) {
        $runtimeConfig["TEST_MODE"] = "false"
    }

    $runtimeLines = foreach ($key in $runtimeConfig.Keys) {
        $value = [string]$runtimeConfig[$key]
        if ($value -match "[`r`n]") {
            throw "Configuration value $key contains a line break."
        }
        "$key=$value"
    }
    [IO.File]::WriteAllLines(
        $runtimeConfigPath,
        [string[]]$runtimeLines,
        [Text.UTF8Encoding]::new($false)
    )
    Set-RestrictedAcl -Path $runtimeConfigPath

    $pythonArguments = @($enginePath, "--config", $runtimeConfigPath)
    if ($CheckConfig) {
        $pythonArguments += "validate"
    } elseif ($CheckLdap) {
        $pythonArguments += "check-ldap"
    } elseif ($ValidateSmtp) {
        $pythonArguments += @("check-mail", "--to", $ValidateSmtp)
    } elseif ($SendTestMail) {
        $pythonArguments += @("check-mail", "--to", $SendTestMail)
    } else {
        $pythonArguments += "run"
    }

    & $PythonPath @pythonArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python engine exited with code $LASTEXITCODE."
    }
} finally {
    foreach ($path in $temporaryPaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
