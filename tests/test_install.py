import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

import install


ROOT = Path(__file__).resolve().parents[1]


class InstallCompatibilityTests(unittest.TestCase):
    def test_legacy_python_entrypoint_delegates_to_install_sh(self):
        with patch("install.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0)

            result = install.main(["--dry-run", "--ui", "plain"])

        self.assertEqual(result, 0)
        run.assert_called_once_with(
            [
                "bash",
                str(ROOT / "install.sh"),
                "--dry-run",
                "--ui",
                "plain",
            ],
            check=False,
        )

    def test_linux_installer_uses_canonical_runtime_subcommands(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn("runtime_check check-ldap", source)
        self.assertIn("runtime_check validate", source)
        self.assertIn('runtime_check check-mail --to "$recipient"', source)
        self.assertIn('"$RUNTIME_PATH" "$check" --config "$CONFIG_PATH"', source)
        self.assertNotIn("runtime_check --check-", source)
        self.assertNotIn("runtime_check --send-test-mail", source)

    def test_linux_cron_invokes_explicit_run_subcommand(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn("%s run --config %s", source)
        self.assertIn(
            '"$RUNTIME_PATH" "$CONFIG_PATH" > "$CRON_PATH"',
            source,
        )

    def test_linux_installer_uses_runtime_smtp_security_values(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn('2) smtp_security="ssl"', source)
        self.assertNotIn('smtp_security="tls"', source)

    def test_linux_installer_does_not_import_network_certificates_into_system_trust(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertIn("install_operator_ca_file", source)
        self.assertIn("Expected SHA-256 fingerprint", source)
        self.assertNotIn("update-ca-certificates", source)
        self.assertNotIn("update-ca-trust", source)

    def test_linux_installer_does_not_use_bash_tcp_interpolation(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")

        self.assertNotIn("/dev/tcp/$host/$port", source)
        self.assertIn("socket.create_connection", source)


if __name__ == "__main__":
    unittest.main()
