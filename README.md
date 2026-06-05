# AD Password Sentinel

AD Password Sentinel notifies IT teams, and optionally users, before Active Directory passwords expire. It is intended to run from cron on a Linux host with LDAP access to AD and a local mail transport such as Postfix.

## Features

- Scans enabled Active Directory users with `msDS-UserPasswordExpiryTimeComputed`.
- Sends a technical summary report to IT.
- Optionally sends end-user warning emails.
- Writes a CSV report for audit and troubleshooting.
- Supports dry-run mail output with `TEST_MODE=true`.
- Includes an interactive Linux installer with cron setup.

## Requirements

- Python 3.9 or newer.
- LDAP network access to a domain controller.
- A least-privilege AD bind account.
- Local `sendmail` interface, usually provided by Postfix, when `TEST_MODE=false`.

Install Python dependencies:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

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

For production Linux installs, the default config path is:

```text
/etc/ad-password-sentinel/config.env
```

## Interactive Linux Install

Run as root:

```bash
python3 install.py
```

The installer prompts for LDAP settings, mail settings, whether to notify users, and cron frequency. The recommended schedule is every day at 08:00.

Cron choices:

- Every day at 08:00, recommended.
- Every Monday at 08:00.
- Monday, Wednesday, Friday at 08:00.

The installer also checks for a local mail transport. If Postfix/sendmail is missing, it can install Postfix on common Linux distributions or leave `TEST_MODE=true` until you configure mail manually.

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
- Phase 2 is not complete: richer terminal UI and guided Postfix configuration are planned.
- Phase 3 is not complete: Windows/PowerShell and Docker-on-Windows support are planned.

Phase 2:

- Improve the installer into a richer interactive shell experience, likely using `gum` when available with a plain shell fallback.
- Add guided Postfix configuration for relay host, sender domain, authentication, and TLS.
- Add guided LDAP/LDAPS setup, including certificate trust checks and an explicit LDAP fallback acknowledgement.
- Add stronger validation for LDAP and mail configuration before cron is installed.

Phase 3:

- Add Windows support with a PowerShell implementation and Task Scheduler setup.
- Evaluate a Windows Server Docker deployment path for environments without Linux infrastructure.
- Document tradeoffs between native Windows mail relay configuration and containerized Linux mail transport.

## License

MIT. See `LICENSE`.
