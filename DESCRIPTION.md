# AD Password Sentinel

AD Password Sentinel is a scheduled Active Directory password-expiration
notification service. It uses LDAPS by default, produces an auditable CSV and
IT report, and can send controlled end-user reminders.

Deploy it with the native Linux installer, the elevated Windows PowerShell
installer, or the hardened one-shot Docker runtime. All paths begin in
`TEST_MODE=true`, support direct SMTP, and recommend daily execution at 08:00.
