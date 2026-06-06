# Security

## Security Model

AD Password Sentinel is an administrative batch job, not an internet-facing
service. Its security depends on a trusted host, a least-privilege AD account,
protected configuration and reports, authenticated encrypted transports, and
restricted scheduler identities.

The application reads directory metadata needed to calculate password expiry.
It does not need domain administrator rights or permission to change accounts.
Use a dedicated read-only bind account and do not reuse its password.

## Transport Security

LDAPS on TCP 636 with hostname and certificate validation is the default.
Private AD certificate authorities must be trusted by the Linux host, Windows
host, or explicitly supplied to the Docker runtime.

LDAP on TCP 389 is an explicit downgrade. It exposes bind credentials and
directory traffic to interception or modification. The runtime rejects that
mode unless `ALLOW_INSECURE_LDAP=true`; installers offer it only after LDAPS
validation fails and default the answer to no.

Use LDAP fallback only temporarily on a trusted, segmented network. Record the
risk acceptance, rotate the bind password after suspected exposure, and restore
LDAPS after repairing DNS, firewalls, or the DC certificate.

## Certificate Trust

Prefer the issuing CA certificate over a server leaf certificate. Verify the
certificate fingerprint, subject, issuer, validity period, hostname/SAN, and
Server Authentication usage before importing it.

- Linux installer: stores the trusted issuing CA in
  `/etc/ad-password-sentinel/ldap-ca.crt` and references it with
  `LDAP_CA_FILE`.
- Docker: provide the CA to `docker/setup.sh` or `docker/setup.ps1`; it is
  mounted read-only and selected through `LDAP_CA_FILE`.

Do not disable certificate validation to work around an expired or
hostname-mismatched certificate.

## Secrets

Never commit generated configuration, secret, certificate, or report files.

Linux stores LDAP and optional SMTP passwords in separate mode-`0640` files
under `/etc/ad-password-sentinel`. Restrict the directory to root and the
`ad-password-sentinel` service account.

Windows stores secrets with LocalMachine DPAPI under
`%ProgramData%\AD Password Sentinel`. ACLs permit only `SYSTEM` and local
Administrators. A copied DPAPI blob is not a substitute for access control and
backups still require protection.

Docker mounts configuration, secrets, and certificates read-only. The
container runs as a non-root user with a read-only root filesystem, all
capabilities dropped, and `no-new-privileges`. Protect the host-side files
because Docker administrators and root can read mounted secrets.

## Test Mode And Mail Safety

Keep `TEST_MODE=true` until all of the following are verified:

1. Configuration validation succeeds.
2. The authenticated LDAP bind succeeds.
3. The generated account list and CSV are correct.
4. A test message reaches the technical recipient.
5. Sender identity, SMTP relay policy, and user mail domains are correct.

Keep `NOTIFY_USERS=false` until the IT report has been reviewed. Set
`USER_MAIL_ALLOWED_DOMAINS` before enabling user messages.

Direct SMTP supports `starttls`, `ssl`/TLS, or `none`; prefer encrypted modes.
An existing local `sendmail` interface is also supported on Linux. Avoid
unauthenticated, unencrypted SMTP outside a controlled relay network.

## Reports And Logs

Reports can contain names, usernames, email addresses, and password-expiration
dates. Restrict access, define retention, protect backups, and avoid attaching
production reports to public issues.

Schedules prevent overlapping runs: Linux uses `flock`; Windows Task Scheduler
uses `IgnoreNew`. Preserve those controls when changing schedules manually.

## Network Boundaries

Allow only required flows:

- Application host or container to domain controllers on TCP 636.
- TCP 389 only during an explicitly accepted LDAP fallback.
- Application host or container to the chosen SMTP relay port.
- DNS to the organization-approved resolvers.

Apply host, network, DC, Docker, and cloud firewalls consistently. Do not expose
LDAP, SMTP, reports, or secret files to untrusted networks.

## Updates And Recovery

Back up configuration, secrets, reports, and scheduler definitions before an
upgrade. Disable the schedule during recovery, restore restrictive
permissions/ACLs, set `TEST_MODE=true`, and repeat config, LDAP, mail, and
report validation before enabling live notifications.

## Reporting Security Issues

Report vulnerabilities privately to the repository owner. Do not include real
credentials, domain names, certificates, directory exports, or reports in a
public issue.
