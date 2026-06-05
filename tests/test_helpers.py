from datetime import datetime, timezone
import unittest

from notify_ad_password_expiry import (
    NEVER_EXPIRES_FILETIME,
    parse_bool,
    parse_notify_days,
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


if __name__ == "__main__":
    unittest.main()
