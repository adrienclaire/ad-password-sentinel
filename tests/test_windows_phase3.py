import unittest

from scripts.windows_task import build_task_command


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


if __name__ == "__main__":
    unittest.main()
