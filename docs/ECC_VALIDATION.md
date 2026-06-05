# ECC Validation

## Stack

- Language: Python.
- Runtime: Linux cron for production execution.
- External dependency: `ldap3`.
- Sensitive surfaces: Active Directory bind credentials, LDAP transport security, local `sendmail`, cron execution, and CSV reports containing employee account metadata.

## Daily Surface

- Python scripting practices: active because the repo contains `notify_ad_password_expiry.py`, `install.py`, and `tests/test_helpers.py`.
- Security review: active because the script handles credentials, sends email, writes PII reports, and is scheduled from cron.
- Verification before completion: active because changes should be proven with syntax checks and unit tests before commit or release.

## Library Surface

- Frontend, TypeScript, React, Supabase, API design, and database skills are library-only for this repo. There is no evidence of those stacks in tracked files.
- Windows and Docker guidance are library-only until Phase 3 starts.
- Product/UI skills become relevant only if Phase 2 adopts a richer terminal UI such as `gum`.

## Install Plan

- Keep the repo lightweight. Do not install full ECC hooks or rules that do not match this Python script.
- Add Python-focused verification when the repo grows: formatting, linting, dependency auditing, and CI.
- Keep production `config.env` files out of git. Ship only `config.env.example`.

## Verification

- `rg --files` confirmed a Python-only repository.
- `git ls-files` confirmed `config.env` is not tracked.
- Security scan focused on `AD_BIND_PASSWORD`, LDAP transport, `sendmail`, cron, report paths, and generated CSV output.
