# AD Password Sentinel

AD Password Sentinel finds enabled Active Directory accounts with expiring
passwords, writes a CSV report, sends an IT summary, and can optionally notify
users. It supports three deployment models:

- Native Linux installation with `install.sh` and cron.
- Native Windows installation with an elevated PowerShell installer and Task
  Scheduler.
- A hardened, one-shot Docker container scheduled by the host.

The native installers use the same Python engine and configuration contract.
New installations begin with LDAPS and `TEST_MODE=true`.

## Before You Install

Prepare:

- A dedicated, read-only AD bind account.
- The domain controller FQDN and, preferably, its IP address as a fallback.
- Network access to TCP 636 for LDAPS.
- The issuing CA certificate when the DC certificate is not publicly trusted.
- The CA certificate SHA-256 fingerprint before you launch the installer. The
  installer can prompt for the CA file during LDAPS recovery, and it is easier
  to complete that step if the fingerprint is already available.
- A sender address, technical report recipient, and mail route.
- Python 3.9 or newer. Docker deployments require Docker Compose.

Keep `TEST_MODE=true` until configuration, LDAP, report contents, and mail
delivery have been validated. Leave `NOTIFY_USERS=false` during validation.

Find the CA certificate fingerprint before installation:

```bash
openssl x509 -in /path/to/domain-ca.cer -noout -fingerprint -sha256
```

To print only the normalized hex digest:

```bash
openssl x509 -in /path/to/domain-ca.cer -noout -fingerprint -sha256 \
  | cut -d= -f2 | tr -d ':'
```

## Linux: Clone And Run

Clone the repository and run the native installer from the checked-out source:

```bash
git clone https://github.com/adrienclaire/ad-password-sentinel.git
cd ad-password-sentinel
sudo ./install.sh
```

To remove the Linux installation later:

```bash
sudo ./uninstall.sh
```

Do not pipe the installer from the network into a root shell. Review the
checked-out script first because it installs files under `/opt` and `/etc`.

The installer uses Whiptail by default when it is installed and usable. It
automatically falls back to plain terminal prompts when Whiptail or a suitable
TTY is unavailable.

```bash
sudo ./install.sh --ui whiptail  # request Whiptail; falls back to plain
sudo ./install.sh --ui plain     # force plain prompts
sudo ./install.sh --dry-run      # questionnaire and actions without changes
```

The installer:

- Creates the unprivileged `ad-password-sentinel` service account.
- Installs the application and virtual environment in
  `/opt/ad-password-sentinel`.
- Writes configuration and separate secret files in
  `/etc/ad-password-sentinel`.
- Writes reports in `/var/log/ad-password-sentinel`.
- Validates the directory and mail route before enabling a cron schedule.
- Uses `flock` to prevent overlapping runs.

The recommended schedule is daily at 08:00. Weekly Monday at 08:00 and
Monday/Wednesday/Friday at 08:00 are also offered.

### Exact Directory Validation Flow

The Linux installer follows this order:

1. Collect the DC FQDN and optional DC IP fallback.
2. Resolve the FQDN with system DNS.
3. If DNS fails and an IP was supplied, add an `/etc/hosts` mapping and use the
   IP for network checks while retaining the FQDN for TLS identity.
4. Test TCP 636 and inspect the LDAPS certificate.
5. Write an LDAPS configuration using port 636, certificate validation, and
   `ALLOW_INSECURE_LDAP=false`.
6. Perform an authenticated LDAPS bind.
7. If the bind fails and the failure is certificate-related, provide an
   operator-supplied issuing CA certificate and its out-of-band SHA-256
   fingerprint. The installer stores it in an application-specific trust file
   and retries LDAPS.
8. Only after LDAPS still fails, offer an explicit downgrade to unencrypted
   LDAP on TCP 389. The default answer is no.
9. If accepted, set `LDAP_MODE=ldap`, `LDAP_PORT=389`,
   `LDAP_TLS_VALIDATE=false`, and `ALLOW_INSECURE_LDAP=true`, then validate the
   bind again.

If directory or mail validation fails or is declined, the installer leaves
`TEST_MODE=true` and does not enable the schedule. After both checks pass, the
Linux installer sets `TEST_MODE=false` and installs cron.

> **LDAP downgrade warning:** LDAP on port 389 does not protect bind
> credentials or directory data with TLS. Use it only as a temporary,
> explicitly accepted fallback on a trusted internal network. Replace or fix
> the DC certificate and return to LDAPS as soon as possible.

### Mail Options

The Linux installer offers:

- Existing local `sendmail` or Postfix.
- Direct SMTP relay, with `starttls`, `ssl`, or `none`. Authentication is
  allowed only with `starttls` or `ssl`.
- Skip mail setup. This aborts schedule activation and retains
  `TEST_MODE=true`.

SMTP and LDAP passwords are stored in separate mode-`0640` files rather than
inline in `config.env`.

## Certificate Trust

Import the issuing CA certificate rather than a leaf certificate when
possible. The Linux installer stores it in `/etc/ad-password-sentinel/ldap-ca.crt`
and references it through `LDAP_CA_FILE`; it does not modify the system trust
store. Importing an expired certificate does not make it valid.

If you want to trust the AD CA system-wide on Linux before running the
installer, use the standard Linux CA store.

Ubuntu and Debian:

```bash
sudo cp /path/to/domain-ca.cer /usr/local/share/ca-certificates/domain-ca.crt
sudo update-ca-certificates
```

RHEL, Rocky Linux, AlmaLinux, and compatible systems:

```bash
sudo cp /path/to/domain-ca.cer /etc/pki/ca-trust/source/anchors/domain-ca.crt
sudo update-ca-trust extract
```

After importing the CA, validate LDAPS directly before running the installer:

```bash
getent hosts dc01.domain.local
openssl s_client -connect dc01.domain.local:636 \
  -servername dc01.domain.local -brief </dev/null
ldapwhoami -x -H ldaps://dc01.domain.local:636 \
  -D "svc_psw_notify@domain.local" -W
```

If those commands succeed and the installer still asks for a certificate, the
certificate is probably not the real problem anymore. The remaining failure is
more likely a bind, hostname, chain, or installer error path.

Inspect a certificate before trusting it:

```bash
openssl s_client -connect dc01.example.local:636 \
  -servername dc01.example.local -showcerts
```

The Linux installer does not auto-trust whatever certificate the DC presents.
That is intentional. Trusting a certificate fetched from the failing endpoint
would be unsafe. The installer only accepts an operator-supplied CA file plus
an expected SHA-256 fingerprint.

## Windows: Elevated PowerShell

Use 64-bit Windows PowerShell from an **elevated** console. Python 3 must be
available as `python.exe`.

```powershell
git clone https://github.com/adrienclaire/ad-password-sentinel.git
Set-Location .\ad-password-sentinel
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-Windows.ps1
```

The installer writes immutable application files under
`%ProgramFiles%\AD Password Sentinel` and restricted configuration, machine
DPAPI secrets, and reports under `%ProgramData%\AD Password Sentinel`.

Windows also starts with LDAPS on 636. It uses the optional DC IP when the FQDN
cannot reach port 636, validates configuration, performs an authenticated bind,
and validates direct SMTP. An LDAP port 389 downgrade is offered only after
LDAPS validation fails and requires explicit acceptance.

The recommended scheduled task runs daily at 08:00 as `SYSTEM`, ignores
overlapping runs, retries failures, and smoke-tests the SYSTEM/DPAPI execution
path. `TEST_MODE` remains true after validation unless the final prompt to
enable live notifications is accepted.

## Docker Setup

Docker is a one-shot runtime. Schedule `docker compose run --rm` on the host;
do not expect a long-running cron daemon inside the container.

Linux or macOS host:

```bash
git clone https://github.com/adrienclaire/ad-password-sentinel.git
cd ad-password-sentinel
./docker/setup.sh
```

Windows PowerShell host:

```powershell
git clone https://github.com/adrienclaire/ad-password-sentinel.git
Set-Location .\ad-password-sentinel
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\docker\setup.ps1
```

Both setup scripts:

- Require the DC FQDN and DC IP fallback.
- Create `config/`, `secrets/`, `certs/`, and `reports/`.
- Generate `TEST_MODE=true`, LDAPS port 636 configuration.
- Map the FQDN to the supplied DC IP inside the container.
- Mount configuration, secrets, and the CA file read-only.
- Build the image, validate configuration, and check the LDAP bind.

For a private CA, provide its certificate when prompted. It is mounted at
`/run/certs/ad-password-sentinel-ca.crt` and referenced by `LDAP_CA_FILE`; the
container does not modify its system trust store at runtime.

Validate mail separately:

```bash
docker compose run --rm ad-password-sentinel check-mail --to it@example.com
```

After reviewing reports, set `TEST_MODE=false` in `config/config.env`. The
recommended Linux host cron entry uses `docker run` directly against trusted
absolute paths rather than `docker compose` from a writable checkout:

```cron
0 8 * * * /usr/bin/docker run --rm --read-only ... ad-password-sentinel:local run
```

On Windows, the setup script can print an equivalent `schtasks` command for a
daily 08:00 run.

Docker image build success and live connectivity to AD and SMTP are
environment-dependent validations. They depend on the local Docker engine,
DNS/routing, firewalls, certificates, credentials, and relay policy.

## Runtime Checks

Native Linux:

```bash
sudo -u ad-password-sentinel \
  /opt/ad-password-sentinel/.venv/bin/python \
  /opt/ad-password-sentinel/notify_ad_password_expiry.py \
  --config /etc/ad-password-sentinel/config.env validate

sudo -u ad-password-sentinel \
  /opt/ad-password-sentinel/.venv/bin/python \
  /opt/ad-password-sentinel/notify_ad_password_expiry.py \
  --config /etc/ad-password-sentinel/config.env check-ldap

sudo -u ad-password-sentinel \
  /opt/ad-password-sentinel/.venv/bin/python \
  /opt/ad-password-sentinel/notify_ad_password_expiry.py \
  --config /etc/ad-password-sentinel/config.env doctor
```

Send a live doctor test mail only when you explicitly want it:

```bash
sudo -u ad-password-sentinel \
  /opt/ad-password-sentinel/.venv/bin/python \
  /opt/ad-password-sentinel/notify_ad_password_expiry.py \
  --config /etc/ad-password-sentinel/config.env \
  doctor --send-test-mail it@example.com
```

Docker:

```bash
docker compose run --rm ad-password-sentinel validate
docker compose run --rm ad-password-sentinel check-ldap
docker compose run --rm ad-password-sentinel run
```

## Upgrade

Back up configuration, secrets, reports, and scheduler definitions first.

Linux:

```bash
git pull --ff-only
sudo ./install.sh
```

Choose to preserve the existing configuration. The installer refreshes the
application and virtual environment, revalidates directory and mail access,
and rewrites cron only after validation succeeds.

Windows: pull or extract the new source, then rerun
`scripts\Install-Windows.ps1` from elevated PowerShell. Review prompts before
overwriting configuration or machine-scoped secrets.

Docker:

```bash
git pull --ff-only
docker compose build --pull
docker compose run --rm ad-password-sentinel validate
docker compose run --rm ad-password-sentinel check-ldap
```

Keep the existing `.env`, `config/`, `secrets/`, `certs/`, and `reports/`
directories. Test the new image before the next scheduled live run.

## Uninstall And Recovery

Linux:

1. Run `sudo ./uninstall.sh`.
2. Confirm the uninstall prompt.
3. Choose whether to keep or delete configuration, secrets, CA files, and
   reports under `/etc` and `/var`.
4. If you kept data for backup or migration, remove it later only when policy
   permits.
5. Run the platform CA trust refresh command only if you also removed a
   certificate that had been imported into the system trust store outside this
   application.

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Uninstall-Windows.ps1
```

Docker:

```bash
./docker/uninstall.sh
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\docker\uninstall.ps1
```

For recovery, disable the schedule first, restore configuration and secrets
with their original permissions/ACLs, set `TEST_MODE=true`, and rerun config,
LDAP, mail, and report validation before re-enabling live notifications.

## Troubleshooting

### LDAPS Port 636

```bash
getent hosts dc01.example.local
nc -vz dc01.example.local 636
openssl s_client -connect dc01.example.local:636 \
  -servername dc01.example.local -verify_return_error
ldapwhoami -x -H ldaps://dc01.example.local:636 \
  -D "svc_bind@example.local" -W
```

On Windows:

```powershell
Resolve-DnsName dc01.example.local
Test-NetConnection dc01.example.local -Port 636
```

Check host, VLAN, site-to-site, cloud security-group, and DC firewalls. LDAPS
also fails when the certificate is expired, lacks Server Authentication usage,
has the wrong hostname, or chains to an untrusted CA.

### LDAP Port 389

Test port 389 only when evaluating the explicit fallback:

```bash
nc -vz dc01.example.local 389
```

```powershell
Test-NetConnection dc01.example.local -Port 389
```

An open port does not make LDAP safe. The application rejects LDAP unless
`ALLOW_INSECURE_LDAP=true`.

### DNS And IP Fallback

Use the DC FQDN for TLS identity. If DNS is unavailable, the native Linux
installer can add an `/etc/hosts` mapping, Docker uses Compose `extra_hosts`,
and Windows can connect through the supplied IP. Fix DNS rather than relying
indefinitely on a static DC address.

### Mail

Confirm the SMTP or sendmail route accepts the configured sender and recipient.
Check relay authorization, TLS mode, port, credentials, outbound firewall
rules, and spam quarantine. A successful LDAP check does not validate mail.

## Security

See [SECURITY.md](SECURITY.md) for the trust model, secret handling, report
sensitivity, Docker hardening, and the risks of LDAP downgrade.

## License

MIT. See [LICENSE](LICENSE).
