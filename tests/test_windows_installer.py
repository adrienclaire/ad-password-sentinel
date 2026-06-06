import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsInstallerTests(unittest.TestCase):
    def test_installer_is_interactive_and_ldaps_first(self):
        source = (ROOT / "scripts" / "Install-Windows.ps1").read_text()

        self.assertIn("Read-Host", source)
        self.assertIn('LDAP_MODE = "ldaps"', source)
        self.assertIn('-Name "LDAP_MODE" -Value "ldap"', source)
        self.assertIn("ALLOW_INSECURE_LDAP", source)
        self.assertIn("Convert-DomainToBaseDn", source)
        self.assertIn("Convert-ShortNameToUpn", source)
        self.assertIn("TEST_MODE", source)

    def test_installer_does_not_schedule_example_config(self):
        source = (ROOT / "scripts" / "Install-Windows.ps1").read_text()

        self.assertIn("Write-EnvironmentFile", source)
        self.assertFalse((ROOT / "config.windows.example.json").exists())

    def test_installer_smoke_tests_registered_system_task_in_test_mode(self):
        source = (ROOT / "scripts" / "Install-Windows.ps1").read_text()

        self.assertIn("Start-ScheduledTask", source)
        self.assertIn("LastTaskResult", source)
        self.assertIn("Unregister-ScheduledTask", source)
        self.assertLess(
            source.index("Start-ScheduledTask"),
            source.index('Set-ConfigValue -Values $config -Name "TEST_MODE" -Value "false"'),
        )

    def test_launcher_uses_canonical_runtime_subcommands(self):
        source = (ROOT / "Notify-AdPasswordExpiry.ps1").read_text()

        self.assertIn('$pythonArguments += "validate"', source)
        self.assertIn('$pythonArguments += "check-ldap"', source)
        self.assertIn('@("check-mail", "--to", $ValidateSmtp)', source)
        self.assertIn("$env:ProgramData", source)


if __name__ == "__main__":
    unittest.main()
