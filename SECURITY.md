# Security

## Supported Use

AD Password Sentinel handles directory credentials and employee account metadata. Run it on a trusted administrative host with least-privilege access to Active Directory.

## Configuration Rules

- Do not commit production `config.env` files.
- Use a dedicated read-only AD service account.
- Prefer LDAPS on port 636 with trusted certificates.
- Plain LDAP is supported for environments where LDAPS is blocked by an expired, self-signed, or untrusted DC certificate. It requires `ALLOW_INSECURE_LDAP=true` so the risk is explicit.
- When using plain LDAP, run only on a trusted internal network, use a low-privilege bind account, and rotate the bind password if the network or host is suspected to be compromised.
- Keep `TEST_MODE=true` until LDAP search, mail routing, and report content are verified.
- Restrict `/etc/ad-password-sentinel/config.env` permissions to root or the service account.
- Restrict `/var/log/ad-password-sentinel` because reports can contain names, usernames, email addresses, and password expiration dates.
- Set `USER_MAIL_ALLOWED_DOMAINS` before enabling end-user notifications.

## Mail Safety

The default runtime uses the local `sendmail` interface. Configure Postfix or another MTA before disabling test mode. Validate sender domains, relay permissions, and mail logs in a non-production run first.

The installer can configure a basic Postfix SMTP relay. Review generated relay settings before using production credentials, and keep `/etc/postfix/sasl_passwd` mode `600` when SMTP auth is enabled.

## LDAPS Certificate Trust

For LDAPS, the Linux VM or container must trust the certificate chain presented by the domain controller. If the DC certificate is valid but untrusted, install the issuing CA certificate or DC certificate into the host trust store:

- Debian/Ubuntu: copy the PEM/CRT file to `/usr/local/share/ca-certificates/` and run `update-ca-certificates`.
- RHEL-compatible systems: copy it to `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust extract`.
- Docker: copy the certificate into the image and run the trust update command during the build.

If the DC certificate is expired, trust-store installation is not enough. Replace the DC certificate when possible, or use the explicit LDAP fallback while accepting the transport risk.

## Scheduled Runs

Cron entries created by the installer use `flock` with `/var/lock/ad-password-sentinel.lock` to prevent overlapping runs. Keep this lock in place when editing cron manually.

The Linux installer runs the application from `/opt/ad-password-sentinel/.venv` so dependency changes are isolated from the system Python installation.

## Windows And Docker

The Windows runner uses a JSON config file containing credentials. Store it under a restricted directory such as `C:\ADPasswordSentinel`, limit ACLs to administrators and the scheduled task identity, and avoid committing it to git.

The Docker path expects `config.env` to be mounted read-only into the container. Treat host-mounted reports as sensitive because they include account metadata and password-expiration dates.

## Reporting Issues

For now, report security issues privately to the repository owner. Do not publish credentials, real domain names, or production reports in issues or pull requests.
