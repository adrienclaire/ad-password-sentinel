# Changelog

All notable changes to this project are documented here.

## Unreleased

### Added

- Native Linux entry point, `install.sh`, with automatic Whiptail selection
  and plain terminal fallback.
- Native Windows installer using a shared Python engine, restricted
  `%ProgramData%` configuration, LocalMachine DPAPI secrets, and a SYSTEM
  scheduled-task smoke test.
- Guided Docker setup for Bash and PowerShell hosts.
- LDAPS-first validation with DNS checks, optional DC IP fallback, certificate
  trust import guidance, and an explicit LDAP downgrade gate.
- Direct SMTP transport with optional authentication alongside existing
  sendmail/Postfix support.
- Host-scheduled, one-shot Docker execution with read-only configuration,
  secret, and certificate mounts.
- Upgrade, uninstall, recovery, security-model, and network troubleshooting
  documentation.

### Changed

- Standardized deployment configuration around `LDAP_*` variables and
  separate password files.
- Kept `TEST_MODE=true` through validation and made live notification
  activation an explicit final step.
- Recommended daily execution at 08:00 across Linux, Windows, and Docker host
  schedulers.
- Reworked documentation around the native installer architecture.

### Security

- Linux installation runs the application as an unprivileged service account
  and uses `flock` to prevent overlapping runs.
- Windows secrets are machine-DPAPI protected and restricted to `SYSTEM` and
  local Administrators.
- Docker runs non-root with a read-only root filesystem, dropped capabilities,
  and `no-new-privileges`.
- Plain LDAP on TCP 389 requires explicit risk acceptance through
  `ALLOW_INSECURE_LDAP=true`.
- Linux no longer imports endpoint-presented certificates into the system trust
  store; operator-supplied CA files are fingerprint-verified and scoped to this
  application.
- Docker scheduler guidance now uses direct `docker run` commands against
  trusted absolute paths instead of `docker compose` from a mutable checkout.

### Validation

- Docker image builds and live AD/SMTP checks remain environment-dependent.
- Native live validation depends on local DNS, routing, firewalls,
  certificates, credentials, and SMTP relay policy.

## 0.1.0 - 2026-06-05

### Added

- Initial AD password-expiration scanner and CSV report.
- IT summary email and optional end-user notifications.
- Safe example configuration and MIT license.
- Linux cron installation, runtime preflight commands, log rotation, and
  Postfix guidance.
- Early Windows PowerShell, Task Scheduler, Dockerfile, and Compose support.
