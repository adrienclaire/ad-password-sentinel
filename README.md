# AD Password Sentinel

AD Password Sentinel notifies IT teams, and optionally users, before Active Directory passwords expire. It is intended to run from cron on a Linux host with LDAP access to AD and a local mail transport such as Postfix.

## Features

- Scans enabled Active Directory users with `msDS-UserPasswordExpiryTimeComputed`.
- Sends a technical summary report to IT.
- Optionally sends end-user warning emails.
- Writes a CSV report for audit and troubleshooting.
- Supports dry-run mail output with `TEST_MODE=true`.
- Includes an interactive Linux installer with cron setup.
- Includes a Windows PowerShell runner and Task Scheduler helper.
- Includes a Docker deployment path for hosts that can run containers.

## Requirements

- Python 3.9 or newer.
- LDAP network access to a domain controller.
- A least-privilege AD bind account.
- Local `sendmail` interface, usually provided by Postfix, when `TEST_MODE=false`.
- Optional: `gum` for nicer installer prompts. The installer starts with plain prompts, asks before using `gum`, and can continue without it.

Install Python dependencies:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

## Installation

Recommended approach: clone the repository, inspect the files, then run the installer. Do not pipe remote scripts directly into a root shell because the installer can write system files, configure cron, and optionally change Postfix.

Linux:

```bash
git clone https://github.com/adrienclaire/ad-password-sentinel.git
cd ad-password-sentinel
sudo python3 install.py
```

If `git` is not installed, download a release archive or the repository ZIP from GitHub, extract it, inspect the files, then run:

```bash
cd ad-password-sentinel
sudo python3 install.py
```

Optional `gum` prompts:

```bash
# Debian/Ubuntu example
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update
sudo apt install gum
```

`gum` is optional. The installer asks before using it, and if it is missing it can offer to install it on supported Linux distributions. If a `gum` prompt cannot render correctly under `sudo`, the installer times out and falls back to plain prompts.

Windows:

```powershell
git clone https://github.com/adrienclaire/ad-password-sentinel.git
cd ad-password-sentinel
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Windows.ps1
```

Docker:

```bash
git clone https://github.com/adrienclaire/ad-password-sentinel.git
cd ad-password-sentinel
cp config.env.example config.env
docker compose up -d --build
```

After installation, keep `TEST_MODE=true` until `--check-config`, `--check-ldap`, and a test email have been validated.

## Configuration

Use `config.env.example` as the reference. Production `config.env` files are ignored by git and must not be committed.

Important defaults:

- `TEST_MODE=true` prints emails instead of sending them.
- `NOTIFY_USERS=false` sends only the IT report.
- `AD_SERVER=ldap://...` is a supported fallback for environments where the DC certificate is expired, untrusted, or cannot be replaced yet.
- Set `ALLOW_INSECURE_LDAP=true` only after accepting that LDAP bind credentials and directory data are not protected by TLS.
- `AD_SERVER=ldaps://...` is recommended when the DC certificate chain is valid and trusted by the Linux host or container.
- `WARNING_DAYS=14` includes accounts expiring within 14 days.
- `NOTIFY_DAYS=14,7,3,1,0` limits notifications to those exact day counts.
- `USER_MAIL_ALLOWED_DOMAINS` can restrict end-user notifications to internal mail domains.

## LDAP vs LDAPS

Use LDAPS when possible:

```text
AD_SERVER=ldaps://dc01.example.local:636
ALLOW_INSECURE_LDAP=false
```

If LDAPS fails because the domain controller certificate is expired, self-signed, or signed by a CA that the Linux host does not trust, you can run over LDAP explicitly:

```text
AD_SERVER=ldap://dc01.example.local:389
ALLOW_INSECURE_LDAP=true
```

That fallback is useful for small or legacy environments where the AD CS CA role no longer exists. Keep it on a trusted internal network, use a least-privilege bind account, and avoid reusing that password elsewhere.

## Trusting A DC Certificate For LDAPS

If the DC has a certificate that is valid but not trusted by the Linux VM, export the issuing CA certificate or the DC certificate in PEM/CRT format and install it into the system trust store.

Debian/Ubuntu:

```bash
sudo cp dc-or-ca.crt /usr/local/share/ca-certificates/ad-password-sentinel-dc.crt
sudo update-ca-certificates
```

RHEL/CentOS/Rocky/Alma:

```bash
sudo cp dc-or-ca.crt /etc/pki/ca-trust/source/anchors/ad-password-sentinel-dc.crt
sudo update-ca-trust extract
```

Then test LDAPS:

```bash
openssl s_client -connect dc01.example.local:636 -showcerts
python3 notify_ad_password_expiry.py --config ./config.env
```

For Docker images based on Debian/Ubuntu, copy the certificate and refresh trust during build:

```dockerfile
COPY dc-or-ca.crt /usr/local/share/ca-certificates/ad-password-sentinel-dc.crt
RUN update-ca-certificates
```

If the certificate is expired, importing it will not make LDAPS reliable. Use the LDAP fallback temporarily and plan a certificate replacement on the DC.

## Manual Run

```bash
cp config.env.example config.env
chmod 600 config.env
python3 notify_ad_password_expiry.py --config ./config.env
```

Useful preflight commands:

```bash
python3 notify_ad_password_expiry.py --config ./config.env --check-config
python3 notify_ad_password_expiry.py --config ./config.env --check-ldap
python3 notify_ad_password_expiry.py --config ./config.env --send-test-mail it-support@example.com
```

For production Linux installs, the default config path is:

```text
/etc/ad-password-sentinel/config.env
```

## Interactive Linux Install

Run as root:

```bash
python3 install.py
```

The installer prompts for LDAP settings, mail settings, whether to notify users, and cron frequency. It starts with plain terminal prompts, then asks whether to use or install `gum` for richer prompts. If `gum` blocks or the terminal is not interactive, it falls back to plain prompts. The recommended schedule is every day at 08:00.

Cron choices:

- Every day at 08:00, recommended.
- Every Monday at 08:00.
- Monday, Wednesday, Friday at 08:00.

The installer also checks for a local mail transport. If Postfix/sendmail is missing, it can install Postfix on common Linux distributions or leave `TEST_MODE=true` until you configure mail manually.

Mail transport choices:

- Use existing sendmail/Postfix.
- Install Postfix.
- Configure a Postfix SMTP relay with relay host, port, TLS, and optional SMTP auth.
- Skip mail setup and keep `TEST_MODE=true`.

Cron entries use `flock` so a slow run does not overlap with the next scheduled run.

The installer also:

- Creates `/opt/ad-password-sentinel/.venv` and installs `requirements.txt`.
- Configures log rotation for reports and logs.
- Backs up Postfix files before relay changes and restores backups if setup fails.
- Offers a post-install verification flow for config, LDAP bind, and test mail.

## Windows Support

Use `Notify-AdPasswordExpiry.ps1` when the environment has no Linux host. It uses the Windows ActiveDirectory module and SMTP settings from `config.windows.example.json`.

Create the DPAPI-protected AD bind credential:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-WindowsCredential.ps1 -UserName svc_ad_password_sentinel@example.local -CredentialPath C:\ADPasswordSentinel\bind-credential.xml
```

Manual test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Notify-AdPasswordExpiry.ps1 -ConfigPath .\config.windows.example.json -CheckConfig
```

Interactive install helper:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Windows.ps1
```

Register a daily 08:00 scheduled task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows_task.ps1 -ScriptPath C:\ADPasswordSentinel\Notify-AdPasswordExpiry.ps1 -ConfigPath C:\ADPasswordSentinel\config.json
```

The Windows path is best when the script runs on a domain-joined Windows Server with RSAT Active Directory tools installed.

## Docker Support

The Docker path is intended for Windows Server or Linux hosts that can run Linux containers and do not have a native Linux VM available.

```bash
cp config.env.example config.env
docker compose up -d --build
```

The container runs cron at 08:00 daily and mounts:

- `./config.env` to `/etc/ad-password-sentinel/config.env`
- `./reports` to `/var/log/ad-password-sentinel`

Optional LDAPS certificate mount:

```yaml
- ./certs/dc-or-ca.crt:/usr/local/share/ca-certificates/ad-password-sentinel-dc.crt:ro
```

When that file is mounted, the container refreshes CA trust at startup.

## Production Safety Checklist

1. Use a dedicated read-only AD bind account.
2. Keep `TEST_MODE=true` for the first run.
3. Validate the CSV and IT report recipients.
4. Configure and test Postfix or another `sendmail` provider.
5. Set restrictive permissions on `/etc/ad-password-sentinel/config.env`.
6. Enable `NOTIFY_USERS=true` only after test output is correct.
7. Define report retention because CSV files contain employee account metadata.

## Roadmap

Status:

- Phase 1 is implemented: shareable Python script, safe config template, Linux installer, cron prompt, docs, and tests.
- Phase 2 is implemented: `gum`-aware installer prompts, LDAP/LDAPS TCP preflight, Postfix relay guidance with backup/rollback, non-overlapping cron, virtualenv install, log rotation, and runtime preflight commands.
- Phase 3 is expanded: Windows PowerShell runner, DPAPI credential helper, Task Scheduler installer, Dockerfile, docker-compose baseline, and optional Docker LDAPS certificate mount are present.

Phase 2:

- Remaining hardening: test on a real Linux server with Postfix and a real domain controller.

Phase 3:

- Validate the PowerShell path on a domain-joined Windows Server.
- Validate Docker networking and mail transport on Windows Server.
- Decide whether Windows should become first-class production support or remain an alternate deployment path.

## License

MIT. See `LICENSE`.
