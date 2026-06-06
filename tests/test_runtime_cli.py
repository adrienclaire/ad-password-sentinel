from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from notify_ad_password_expiry import (
    send_local_mail,
    validate_config,
)


class RuntimeConfigTests(unittest.TestCase):
    def base_config(self, directory):
        ldap_secret = Path(directory) / "ldap-password"
        ldap_secret.write_text("ldap-secret\n", encoding="utf-8")
        return {
            "TEST_MODE": "false",
            "LDAP_MODE": "ldaps",
            "LDAP_HOST": "dc01.example.local",
            "LDAP_PORT": "636",
            "LDAP_BASE_DN": "DC=example,DC=local",
            "LDAP_BIND_USER": "svc@example.local",
            "LDAP_PASSWORD_FILE": str(ldap_secret),
            "LDAP_TLS_VALIDATE": "true",
            "MAIL_FROM": "noreply@example.com",
            "TECH_REPORT_TO": "admin@example.com",
            "MAIL_TRANSPORT": "smtp",
            "SMTP_HOST": "smtp.example.com",
            "SMTP_PORT": "587",
            "SMTP_SECURITY": "starttls",
        }

    def test_production_rejects_inline_legacy_ldap_password(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.base_config(directory)
            config.pop("LDAP_PASSWORD_FILE")
            config["AD_BIND_PASSWORD"] = "legacy-secret"
            with self.assertRaisesRegex(RuntimeError, "LDAP_PASSWORD_FILE"):
                validate_config(config, Path(directory) / "config.env")

    def test_plain_ldap_requires_explicit_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.base_config(directory)
            config["LDAP_MODE"] = "ldap"
            config["LDAP_PORT"] = "389"
            with self.assertRaisesRegex(RuntimeError, "ALLOW_INSECURE_LDAP"):
                validate_config(config, Path(directory) / "config.env")

    def test_production_smtp_config_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.base_config(directory)
            validate_config(config, Path(directory) / "config.env")

    def test_smtp_authentication_requires_tls(self):
        with tempfile.TemporaryDirectory() as directory:
            smtp_secret = Path(directory) / "smtp-password"
            smtp_secret.write_text("smtp-secret\n", encoding="utf-8")
            config = self.base_config(directory)
            config["SMTP_SECURITY"] = "none"
            config["SMTP_USER"] = "mailer"
            config["SMTP_PASSWORD_FILE"] = str(smtp_secret)
            with self.assertRaisesRegex(RuntimeError, "SMTP authentication requires"):
                validate_config(config, Path(directory) / "config.env")

    def test_invalid_test_mode_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.base_config(directory)
            config["TEST_MODE"] = "maybe"
            with self.assertRaisesRegex(RuntimeError, "TEST_MODE"):
                validate_config(config, Path(directory) / "config.env")

    @patch("notify_ad_password_expiry.smtplib.SMTP")
    def test_smtp_transport_sends_message(self, smtp_class):
        smtp = smtp_class.return_value.__enter__.return_value
        config = {
            "TEST_MODE": "false",
            "MAIL_TRANSPORT": "smtp",
            "MAIL_FROM": "noreply@example.com",
            "TECH_REPORT_TO": "admin@example.com",
            "SMTP_HOST": "smtp.example.com",
            "SMTP_PORT": "587",
            "SMTP_SECURITY": "starttls",
        }
        send_local_mail(config, "admin@example.com", "Test", "Body")
        smtp_class.assert_called_once_with("smtp.example.com", 587, timeout=30)
        smtp.starttls.assert_called_once()
        smtp.send_message.assert_called_once()

    @patch("notify_ad_password_expiry.smtplib.SMTP")
    def test_smtp_transport_rejects_authentication_without_tls(self, smtp_class):
        config = {
            "TEST_MODE": "false",
            "MAIL_TRANSPORT": "smtp",
            "MAIL_FROM": "noreply@example.com",
            "TECH_REPORT_TO": "admin@example.com",
            "SMTP_HOST": "smtp.example.com",
            "SMTP_PORT": "25",
            "SMTP_SECURITY": "none",
            "SMTP_USER": "mailer",
            "SMTP_PASSWORD": "inline-test-secret",
        }
        with self.assertRaisesRegex(RuntimeError, "SMTP authentication requires"):
            send_local_mail(config, "admin@example.com", "Test", "Body")
        smtp_class.assert_called_once_with("smtp.example.com", 25, timeout=30)


if __name__ == "__main__":
    unittest.main()
