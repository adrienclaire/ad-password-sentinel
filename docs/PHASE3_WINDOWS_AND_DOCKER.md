# Phase 3: Windows And Docker

Phase 3 provides two alternatives for environments without a Linux server.

## Option A: Native Windows

Use the PowerShell runner when you have a domain-joined Windows Server with RSAT Active Directory tools installed.

Files:

- `Notify-AdPasswordExpiry.ps1`
- `config.windows.example.json`
- `scripts/windows_task.ps1`

Recommended flow:

1. Copy the files to `C:\ADPasswordSentinel`.
2. Create `C:\ADPasswordSentinel\config.json` from `config.windows.example.json`.
3. Restrict ACLs on the config file.
4. Run `-CheckConfig`.
5. Run `-CheckLdap`.
6. Run `-SendTestMail`.
7. Register the scheduled task.

Native Windows avoids Linux mail transport complexity, but it depends on the ActiveDirectory PowerShell module and local SMTP relay access.

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

Docker keeps the Python/Linux runtime consistent, but mail relay and domain-controller network access must be configured from the container network.
