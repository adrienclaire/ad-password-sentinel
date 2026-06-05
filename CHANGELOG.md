# Changelog

## 0.1.0 - 2026-06-05

- Renamed the app to AD Password Sentinel.
- Added safe placeholder configuration with no real organization details.
- Added MIT license.
- Added configurable config/report paths.
- Added optional end-user notifications.
- Added installer prompts for Linux deployment and cron scheduling.
- Added ECC-style validation notes.
- Added Phase 2 installer improvements with optional `gum`, LDAP preflight, Postfix relay guidance, non-overlapping cron, and runtime preflight commands.
- Completed Phase 2 with virtualenv installation, log rotation, post-install verification, and Postfix backup/rollback.
- Started Phase 3 with a PowerShell runner, Windows Task Scheduler helper, Dockerfile, and docker-compose baseline.
- Expanded Phase 3 with DPAPI credential support for Windows and optional LDAPS certificate mounting for Docker.
- Added Python dependency list and professional project documentation.
