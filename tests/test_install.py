import unittest

from install import (
    build_cron_command,
    build_postfix_relay_commands,
    cron_expression,
    ldap_port_from_server,
)


class InstallTests(unittest.TestCase):
    def test_cron_expression_supports_named_schedules(self):
        self.assertEqual(cron_expression("daily"), "0 8 * * *")
        self.assertEqual(cron_expression("weekly"), "0 8 * * 1")
        self.assertEqual(cron_expression("three-times-weekly"), "0 8 * * 1,3,5")

    def test_cron_expression_keeps_numeric_choices_for_compatibility(self):
        self.assertEqual(cron_expression("1"), "0 8 * * *")
        self.assertEqual(cron_expression("2"), "0 8 * * 1")
        self.assertEqual(cron_expression("3"), "0 8 * * 1,3,5")

    def test_build_cron_command_uses_flock_to_prevent_overlap(self):
        command = build_cron_command("0 8 * * *")
        self.assertIn("/usr/bin/flock -n /var/lock/ad-password-sentinel.lock", command)
        self.assertIn("--config /etc/ad-password-sentinel/config.env", command)

    def test_ldap_port_from_server_detects_scheme_default_ports(self):
        self.assertEqual(ldap_port_from_server("ldap://dc01.example.local"), ("dc01.example.local", 389))
        self.assertEqual(ldap_port_from_server("ldaps://dc01.example.local"), ("dc01.example.local", 636))

    def test_ldap_port_from_server_honors_explicit_port(self):
        self.assertEqual(ldap_port_from_server("ldap://dc01.example.local:1389"), ("dc01.example.local", 1389))

    def test_build_postfix_relay_commands_includes_tls_and_auth_when_requested(self):
        commands = build_postfix_relay_commands(
            relay_host="smtp.example.com",
            relay_port="587",
            smtp_user="mailer@example.com",
            smtp_password="secret",
            use_tls=True,
        )

        joined = "\n".join(" ".join(command) for command in commands)
        self.assertIn("relayhost=[smtp.example.com]:587", joined)
        self.assertIn("smtp_use_tls=yes", joined)
        self.assertIn("smtp_sasl_auth_enable=yes", joined)


if __name__ == "__main__":
    unittest.main()
