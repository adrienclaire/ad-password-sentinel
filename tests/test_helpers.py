from datetime import datetime, timezone
import unittest

from notify_ad_password_expiry import (
    NEVER_EXPIRES_FILETIME,
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

    def test_validate_email_rejects_header_injection(self):
        with self.assertRaises(RuntimeError):
            validate_email("user@example.com\nBcc: attacker@example.com", "recipient")

    def test_validate_sendmail_path_requires_absolute_path(self):
        with self.assertRaises(RuntimeError):
            validate_sendmail_path("sendmail")

    def test_parse_args_supports_check_config(self):
        args = parse_args(["--config", "config.env", "--check-config"])
        self.assertEqual(args.config, "config.env")
        self.assertTrue(args.check_config)

    def test_parse_args_supports_test_mail_recipient(self):
        args = parse_args(["--send-test-mail", "admin@example.com"])
        self.assertEqual(args.send_test_mail, "admin@example.com")


if __name__ == "__main__":
    unittest.main()
