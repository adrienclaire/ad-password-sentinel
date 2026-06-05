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
- `AD_SERVER=ldaps://...` is recommended. Plain `ldap://` requires `ALLOW_INSECURE_LDAP=true` and should be limited to temporary testing.
- `WARNING_DAYS=14` includes accounts expiring within 14 days.
- `NOTIFY_DAYS=14,7,3,1,0` limits notifications to those exact day counts.
- `USER_MAIL_ALLOWED_DOMAINS` can restrict end-user notifications to internal mail domains.

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
- Add stronger validation for LDAP and mail configuration before cron is installed.

Phase 3:

- Add Windows support with a PowerShell implementation and Task Scheduler setup.
- Evaluate a Windows Server Docker deployment path for environments without Linux infrastructure.
- Document tradeoffs between native Windows mail relay configuration and containerized Linux mail transport.

## License

MIT. See `LICENSE`.
