from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest

from notify_ad_password_expiry import (
    NEVER_EXPIRES_FILETIME,
    get_ldap_url,
    load_secret,
    normalize_config,
    parse_bool,
    parse_notify_days,
    validate_email,
    validate_ldap_security,
    validate_sendmail_path,
    parse_args,
    windows_filetime_to_datetime,
)


class HelperTests(unittest.TestCase):
    def test_parse_bool_accepts_common_true_values(self):
        self.assertTrue(parse_bool("true"))
        self.assertTrue(parse_bool("1"))
        self.assertTrue(parse_bool("yes"))
        self.assertFalse(parse_bool("false"))

    def test_parse_notify_days(self):
        self.assertEqual(parse_notify_days("14, 7,3,1,0"), [14, 7, 3, 1, 0])
        self.assertEqual(parse_notify_days(""), [])
        self.assertEqual(parse_notify_days(None), [])

    def test_windows_filetime_handles_never_expires(self):
        self.assertIsNone(windows_filetime_to_datetime(NEVER_EXPIRES_FILETIME))

    def test_windows_filetime_converts_epoch(self):
        result = windows_filetime_to_datetime(116444736000000000)
        self.assertEqual(result, datetime(1970, 1, 1, tzinfo=timezone.utc))

    def test_validate_ldap_security_rejects_plain_ldap_by_default(self):
        with self.assertRaises(RuntimeError):
            validate_ldap_security({"AD_SERVER": "ldap://dc01.example.local:389"})

    def test_validate_ldap_security_allows_ldaps(self):
        validate_ldap_security({"AD_SERVER": "ldaps://dc01.example.local:636"})

    def test_validate_ldap_security_allows_plain_ldap_when_explicit(self):
        validate_ldap_security({
            "AD_SERVER": "ldap://dc01.example.local:389",
            "ALLOW_INSECURE_LDAP": "true",
        })

    def test_normalize_config_derives_ldaps_url(self):
        config = normalize_config({
            "LDAP_HOST": "dc01.example.local",
            "LDAP_BASE_DN": "DC=example,DC=local",
            "LDAP_BIND_USER": "svc@example.local",
        })
        self.assertEqual(config["LDAP_MODE"], "ldaps")
        self.assertEqual(config["LDAP_PORT"], "636")
        self.assertEqual(get_ldap_url(config), "ldaps://dc01.example.local:636")

    def test_normalize_config_maps_legacy_ldap_names(self):
        config = normalize_config({
            "AD_SERVER": "ldaps://dc01.example.local:1636",
            "AD_BASE_DN": "DC=example,DC=local",
            "AD_BIND_USER": "svc@example.local",
            "AD_BIND_PASSWORD": "test-only",
        })
        self.assertEqual(config["LDAP_HOST"], "dc01.example.local")
        self.assertEqual(config["LDAP_PORT"], "1636")
        self.assertEqual(config["LDAP_BASE_DN"], "DC=example,DC=local")
        self.assertEqual(config["LDAP_BIND_USER"], "svc@example.local")

    def test_load_secret_reads_file_and_strips_trailing_newline(self):
        with tempfile.TemporaryDirectory() as directory:
            secret_path = Path(directory) / "ldap-password"
            secret_path.write_text("secret-value\n", encoding="utf-8")
            self.assertEqual(load_secret(str(secret_path), "LDAP password"), "secret-value")

    def test_validate_email_rejects_header_injection(self):
        with self.assertRaises(RuntimeError):
            validate_email("user@example.com\nBcc: attacker@example.com", "recipient")

    def test_validate_sendmail_path_requires_absolute_path(self):
        with self.assertRaises(RuntimeError):
            validate_sendmail_path("sendmail")

    def test_load_secret_allows_root_service_style_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            secret_path = Path(directory) / "ldap-password"
            secret_path.write_text("secret-value\n", encoding="utf-8")
            if hasattr(secret_path, "chmod"):
                secret_path.chmod(0o640)
            self.assertEqual(load_secret(str(secret_path), "LDAP password"), "secret-value")

    def test_parse_args_supports_check_config(self):
        args = parse_args(["--config", "config.env", "--check-config"])
        self.assertEqual(args.config, "config.env")
        self.assertTrue(args.check_config)

    def test_parse_args_supports_test_mail_recipient(self):
        args = parse_args(["--send-test-mail", "admin@example.com"])
        self.assertEqual(args.send_test_mail, "admin@example.com")
        self.assertEqual(args.command, "check-mail")

    def test_parse_args_supports_subcommands(self):
        args = parse_args(["--config", "config.env", "check-mail", "--to", "admin@example.com"])
        self.assertEqual(args.config, "config.env")
        self.assertEqual(args.command, "check-mail")
        self.assertEqual(args.mail_to, "admin@example.com")

    def test_parse_args_accepts_config_after_subcommand(self):
        args = parse_args(["validate", "--config", "config.env"])
        self.assertEqual(args.config, "config.env")
        self.assertEqual(args.command, "validate")


if __name__ == "__main__":
    unittest.main()
