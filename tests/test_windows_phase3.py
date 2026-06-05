import unittest

from scripts.windows_task import build_credential_export_command, build_task_command


class WindowsPhase3Tests(unittest.TestCase):
    def test_build_task_command_uses_daily_8am_default(self):
        command = build_task_command(
            script_path="C:\\ADPasswordSentinel\\Notify-AdPasswordExpiry.ps1",
            config_path="C:\\ADPasswordSentinel\\config.json",
        )

        self.assertIn("/SC DAILY", command)
        self.assertIn("/ST 08:00", command)
        self.assertIn("Notify-AdPasswordExpiry.ps1", command)
        self.assertIn("config.json", command)

    def test_build_credential_export_command_uses_clixml(self):
        command = build_credential_export_command(
            username="svc_ad_password_sentinel@example.local",
            credential_path="C:\\ADPasswordSentinel\\bind-credential.xml",
        )

        self.assertIn("Get-Credential", command)
        self.assertIn("Export-Clixml", command)
        self.assertIn("bind-credential.xml", command)


if __name__ == "__main__":
    unittest.main()
