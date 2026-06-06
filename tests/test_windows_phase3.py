import unittest
from pathlib import Path


class WindowsPhase3Tests(unittest.TestCase):
    def test_task_uses_system_and_daily_trigger(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "scripts" / "windows_task.ps1").read_text()

        self.assertIn("New-ScheduledTaskTrigger -Daily", source)
        self.assertIn('-UserId "SYSTEM"', source)
        self.assertIn("-RunLevel Highest", source)
        self.assertIn("Notify-AdPasswordExpiry.ps1", source)
        self.assertIn("config.env", source)

    def test_powershell_sources_use_machine_dpapi_and_system_identity(self):
        root = Path(__file__).resolve().parents[1]
        credential_source = (root / "scripts" / "New-WindowsCredential.ps1").read_text()
        task_source = (root / "scripts" / "windows_task.ps1").read_text()

        self.assertIn("DataProtectionScope]::LocalMachine", credential_source)
        self.assertNotIn("Export-Clixml", credential_source)
        self.assertIn('-UserId "SYSTEM"', task_source)
        self.assertIn("-LogonType ServiceAccount", task_source)

    def test_task_has_overlap_retry_and_timeout_controls(self):
        root = Path(__file__).resolve().parents[1]
        task_source = (root / "scripts" / "windows_task.ps1").read_text()

        self.assertIn("-MultipleInstances IgnoreNew", task_source)
        self.assertIn("-RestartCount 3", task_source)
        self.assertIn("-RestartInterval", task_source)
        self.assertIn("-ExecutionTimeLimit", task_source)

    def test_installer_uses_program_files_program_data_and_validation_gate(self):
        root = Path(__file__).resolve().parents[1]
        installer_source = (root / "scripts" / "Install-Windows.ps1").read_text()

        self.assertIn("$env:ProgramFiles", installer_source)
        self.assertIn("$env:ProgramData", installer_source)
        self.assertIn("Test-IsAdministrator", installer_source)
        self.assertIn("Set-RestrictedAcl", installer_source)
        self.assertIn("Test-Installation", installer_source)
        self.assertLess(
            installer_source.index("Test-Installation"),
            installer_source.index("windows_task.ps1"),
        )

    def test_launcher_uses_shared_python_engine_and_direct_smtp_without_send_mail_message(self):
        root = Path(__file__).resolve().parents[1]
        launcher_source = (root / "Notify-AdPasswordExpiry.ps1").read_text()

        self.assertIn("notify_ad_password_expiry.py", launcher_source)
        self.assertIn("LDAP_PASSWORD_FILE", launcher_source)
        self.assertIn("SMTP_PASSWORD_FILE", launcher_source)
        self.assertIn("MAIL_TRANSPORT", launcher_source)
        self.assertIn("DataProtectionScope]::LocalMachine", launcher_source)
        self.assertNotIn("AD_BIND_PASSWORD", launcher_source)
        self.assertNotIn("Send-MailMessage", launcher_source)


if __name__ == "__main__":
    unittest.main()
