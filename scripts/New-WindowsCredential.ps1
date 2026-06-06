param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("AdBind", "Smtp")]
    [string]$CredentialName,

    [Parameter(Mandatory = $true)]
    [string]$UserName,

    [string]$SecretPath = (Join-Path $env:ProgramData "AD Password Sentinel\secrets.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-RestrictedAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$Directory
    )

    $systemSid = [System.Security.Principal.SecurityIdentifier]::new(
        [System.Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new(
        [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null
    )
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }

    if ($Directory) {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    } else {
        $acl = [System.Security.AccessControl.FileSecurity]::new()
    }

    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function ConvertTo-MachineProtectedString {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureString)
    try {
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
        $bytes = [Text.Encoding]::UTF8.GetBytes($plainText)
        try {
            $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
                $bytes,
                $null,
                [Security.Cryptography.DataProtectionScope]::LocalMachine
            )
            return [Convert]::ToBase64String($protectedBytes)
        } finally {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
}

$secretDirectory = Split-Path -Parent $SecretPath
New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
Set-RestrictedAcl -Path $secretDirectory -Directory

$password = Read-Host "Password for $UserName ($CredentialName)" -AsSecureString
$protectedPassword = ConvertTo-MachineProtectedString -SecureString $password

$secretDocument = [ordered]@{ Version = 1 }
if (Test-Path -LiteralPath $SecretPath) {
    $existing = Get-Content -LiteralPath $SecretPath -Raw | ConvertFrom-Json
    foreach ($property in $existing.PSObject.Properties) {
        $secretDocument[$property.Name] = $property.Value
    }
}

$secretDocument[$CredentialName] = [ordered]@{
    UserName = $UserName
    Password = $protectedPassword
}

$temporaryPath = "$SecretPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
    $secretDocument | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Set-RestrictedAcl -Path $temporaryPath
    Move-Item -LiteralPath $temporaryPath -Destination $SecretPath -Force
    Set-RestrictedAcl -Path $SecretPath
} finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Host "Stored $CredentialName using machine-scope DPAPI at $SecretPath."
