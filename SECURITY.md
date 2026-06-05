# Security

## Supported Use

AD Password Sentinel handles directory credentials and employee account metadata. Run it on a trusted administrative host with least-privilege access to Active Directory.

## Configuration Rules

- Do not commit production `config.env` files.
- Use a dedicated read-only AD service account.
- Prefer LDAPS on port 636 with trusted certificates. Plain LDAP requires `ALLOW_INSECURE_LDAP=true` and should not be used in production.
- Keep `TEST_MODE=true` until LDAP search, mail routing, and report content are verified.
- Restrict `/etc/ad-password-sentinel/config.env` permissions to root or the service account.
- Restrict `/var/log/ad-password-sentinel` because reports can contain names, usernames, email addresses, and password expiration dates.
- Set `USER_MAIL_ALLOWED_DOMAINS` before enabling end-user notifications.

## Mail Safety

The default runtime uses the local `sendmail` interface. Configure Postfix or another MTA before disabling test mode. Validate sender domains, relay permissions, and mail logs in a non-production run first.

## Reporting Issues

For now, report security issues privately to the repository owner. Do not publish credentials, real domain names, or production reports in issues or pull requests.
