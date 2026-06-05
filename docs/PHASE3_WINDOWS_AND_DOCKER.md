# Phase 3: Windows And Docker

Phase 3 provides two alternatives for environments without a Linux server.

## Option A: Native Windows

Use the PowerShell runner when you have a domain-joined Windows Server with RSAT Active Directory tools installed.

Files:

- `Notify-AdPasswordExpiry.ps1`
- `config.windows.example.json`
- `scripts/New-WindowsCredential.ps1`
- `scripts/Install-Windows.ps1`
- `scripts/windows_task.ps1`

Recommended flow:

1. Copy the files to `C:\ADPasswordSentinel`.
2. Create `C:\ADPasswordSentinel\config.json` from `config.windows.example.json`.
3. Create `C:\ADPasswordSentinel\bind-credential.xml` with `scripts/New-WindowsCredential.ps1`.
4. Restrict ACLs on the config and credential files.
5. Run `-CheckConfig`.
6. Run `-CheckLdap`.
7. Run `-SendTestMail`.
8. Register the scheduled task.

Native Windows avoids Linux mail transport complexity, but it depends on the ActiveDirectory PowerShell module and local SMTP relay access.

The credential XML is protected by Windows DPAPI. It should be created by the same account context that will run the scheduled task.

## Option B: Docker

Use Docker when the organization can run Linux containers but does not want to maintain a Linux VM.

Files:

- `Dockerfile`
- `docker-compose.yml`
- `docker/crontab`
- `docker/entrypoint.sh`

Recommended flow:

1. Copy `config.env.example` to `config.env`.
2. Keep `TEST_MODE=true`.
3. Run `docker compose up -d --build`.
4. Inspect `./reports/cron.log`.
5. Run a manual container command for `--check-ldap` if network access is uncertain.

For LDAPS trust issues, mount a valid DC or CA certificate:

```yaml
- ./certs/dc-or-ca.crt:/usr/local/share/ca-certificates/ad-password-sentinel-dc.crt:ro
```

The entrypoint refreshes the container CA store when that certificate is present.

Docker keeps the Python/Linux runtime consistent, but mail relay and domain-controller network access must be configured from the container network.
