# AD Password Sentinel

AD Password Sentinel is a small Linux-friendly notification runner for Active Directory password expiration. It scans enabled AD user accounts, writes a CSV report, sends an IT summary, and can optionally notify end users before their password expires.

The project is designed for scheduled execution from cron. The recommended schedule is every day at 08:00 so users and support teams receive warnings early in the business day.
