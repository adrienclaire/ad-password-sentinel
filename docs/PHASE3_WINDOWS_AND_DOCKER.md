# Windows And Docker Deployment

The Windows and Docker paths use the same Python engine as native Linux. They
are alternatives for environments where a Linux service host is unavailable or
where the organization standardizes on Windows Task Scheduler or containers.

## Native Windows

### Requirements

- 64-bit Windows with an elevated Windows PowerShell console.
- Python 3 available as `python.exe`.
- DNS or a known DC IP route to Active Directory.
- TCP 636 to the DC and access to a direct SMTP relay.

### Install

```powershell
git clone https://github.com/adrienclaire/ad-password-sentinel.git
Set-Location .\ad-password-sentinel
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-Windows.ps1
```

Application files are installed under `%ProgramFiles%\AD Password Sentinel`.
Configuration, machine-DPAPI secrets, and reports are stored under
`%ProgramData%\AD Password Sentinel` with ACLs restricted to `SYSTEM` and local
Administrators.

The installer attempts LDAPS on 636 first. If the DC FQDN is unreachable and
the optional IP fallback reaches port 636, it uses that IP for connectivity;
certificate hostname validation can still fail. Only after authenticated LDAPS
validation fails does the installer offer unencrypted LDAP on port 389, and it
requires explicit acceptance.

The installer validates configuration, LDAP, direct SMTP, and the SYSTEM task
identity. The default task time is daily at 08:00. `TEST_MODE=true` remains in
place unless the final live-notification prompt is accepted.

### Operations

Manual checks:

```powershell
& "$env:ProgramFiles\AD Password Sentinel\Notify-AdPasswordExpiry.ps1" `
  -CheckConfig

& "$env:ProgramFiles\AD Password Sentinel\Notify-AdPasswordExpiry.ps1" `
  -CheckLdap

& "$env:ProgramFiles\AD Password Sentinel\Notify-AdPasswordExpiry.ps1" `
  -SendTestMail it@example.com
```

Before upgrades, export reports and back up `%ProgramData%\AD Password
Sentinel`. Rerun the elevated installer from the updated source. For recovery,
disable the scheduled task, restore files and ACLs, set `TEST_MODE=true`, and
repeat all checks.

To uninstall, unregister the `AD Password Sentinel` task, then remove the
Program Files directory. Remove ProgramData only after confirming that reports
and machine-protected secrets are no longer required.

## Docker

### Architecture

The image is a non-root, read-only, one-shot job. Docker Compose mounts:

- `config/config.env` read-only.
- LDAP and SMTP secret files read-only.
- `certs/ca.crt` read-only.
- `reports/` writable.

Compose also maps the DC FQDN to the supplied DC IP inside the container,
providing a deterministic fallback when container DNS cannot resolve AD.

### Bash Setup

```bash
git clone https://github.com/adrienclaire/ad-password-sentinel.git
cd ad-password-sentinel
./docker/setup.sh
```

### PowerShell Setup

```powershell
git clone https://github.com/adrienclaire/ad-password-sentinel.git
Set-Location .\ad-password-sentinel
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\docker\setup.ps1
```

Both scripts collect LDAPS and direct SMTP settings, generate protected
host-side files, build the image, validate configuration, and perform an LDAP
bind. They leave `TEST_MODE=true`.

For private PKI, supply the issuing CA certificate when prompted. It is mounted
at `/run/certs/ad-password-sentinel-ca.crt` and configured through
`LDAP_CA_FILE`. An empty placeholder is mounted when no custom CA is needed.

### Validate And Schedule

```bash
docker compose run --rm ad-password-sentinel validate
docker compose run --rm ad-password-sentinel check-ldap
docker compose run --rm ad-password-sentinel check-mail --to it@example.com
docker compose run --rm ad-password-sentinel run
```

Review the generated report before changing `TEST_MODE=false`. Schedule the
one-shot command on the host, preferably daily at 08:00:

```cron
0 8 * * * /usr/bin/docker run --rm --read-only ... ad-password-sentinel:local run
```

The PowerShell setup script can print a matching Windows `schtasks` command.

Docker image build and live AD/SMTP validation are environment-dependent. They
require a working Docker engine, suitable CPU/image support, DNS/routing,
firewall access, a valid certificate chain, correct credentials, and an SMTP
relay that accepts the container's traffic.

### Upgrade And Recovery

Preserve `.env`, `config/`, `secrets/`, `certs/`, and `reports/`, then:

```bash
git pull --ff-only
docker compose build --pull
docker compose run --rm ad-password-sentinel validate
docker compose run --rm ad-password-sentinel check-ldap
```

For recovery, disable the host schedule, restore the mounted files with
restrictive permissions, set `TEST_MODE=true`, and validate LDAP, mail, and
reports before resuming.

For uninstall, remove the host scheduler entry and run `docker compose down`.
Archive or delete generated host files according to secret and report retention
policy.

## Network Troubleshooting

Test TCP 636 first. Check DNS, routing, host firewalls, container firewall
rules, cloud security groups, and DC firewalls. Inspect the DC certificate for
expiry, hostname/SAN mismatch, missing Server Authentication usage, and an
untrusted issuer.

Port 389 is only for the explicit unencrypted LDAP fallback. An open port does
not remove the confidentiality risk. SMTP must also be reachable on the
configured port, commonly 587 for STARTTLS or 465 for implicit TLS.
