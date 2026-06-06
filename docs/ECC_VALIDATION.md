# Validation Status

## Automated And Repository-Level Validation

The repository contains automated coverage for the shared Python runtime,
native Linux installer flow, installer UI fallback, Windows installer helpers,
Docker configuration, and runtime command routing.

Documentation and configuration examples must continue to preserve these
invariants:

- LDAPS on TCP 636 is the default.
- LDAP on TCP 389 requires `ALLOW_INSECURE_LDAP=true`.
- `TEST_MODE=true` is the initial state.
- Secrets are stored separately from normal configuration.
- User notifications are disabled by default.
- Daily 08:00 is the recommended schedule.

## Environment-Dependent Validation

The following cannot be established by repository tests alone:

- Building the Docker image on every target engine and architecture.
- Authenticating against a live Active Directory domain.
- Verifying a production DC certificate chain.
- Confirming host, VLAN, VPN, cloud, and DC firewall policy for ports 636/389.
- Delivering through a live SMTP relay and confirming downstream receipt.
- Running the Windows SYSTEM task with the target organization's endpoint
  security and Group Policy.

Treat Docker image build and live AD/SMTP checks as environment-dependent
validation. Perform them in the target environment with `TEST_MODE=true`.

## Release Validation Checklist

1. Run repository tests and shell/PowerShell syntax checks.
2. Exercise `sudo ./install.sh --dry-run` with Whiptail and plain prompts.
3. Validate DNS and the optional DC IP fallback.
4. Validate an authenticated LDAPS bind on port 636.
5. Validate private CA import or Docker CA mounting where applicable.
6. Confirm LDAP downgrade is declined by default and clearly warns about port
   389.
7. Validate SMTP or sendmail with a controlled technical recipient.
8. Inspect CSV and email content while `TEST_MODE=true`.
9. Confirm scheduler identity, permissions, non-overlap behavior, and the daily
   08:00 recommendation.
10. Enable live mode only after target-environment approval.
