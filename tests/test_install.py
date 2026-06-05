import unittest

from install import (
    build_cron_command,
    build_logrotate_config,
    build_postfix_relay_commands,
    build_postfix_backup_path,
    build_post_install_verification_commands,
    build_venv_python_path,
    cron_expression,
    ldap_port_from_server,
    should_use_gum,
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

    def test_build_venv_python_path_uses_install_dir(self):
        self.assertEqual(build_venv_python_path(), "/opt/ad-password-sentinel/.venv/bin/python")

    def test_build_cron_command_uses_venv_python_when_requested(self):
        command = build_cron_command("0 8 * * *", python_path="/opt/ad-password-sentinel/.venv/bin/python")
        self.assertIn("/opt/ad-password-sentinel/.venv/bin/python", command)

    def test_build_logrotate_config_rotates_reports_and_logs(self):
        config = build_logrotate_config()
        self.assertIn("/var/log/ad-password-sentinel/*.csv", config)
        self.assertIn("rotate 12", config)
        self.assertIn("missingok", config)

    def test_build_postfix_backup_path_is_timestamped(self):
        path = build_postfix_backup_path("main.cf", "20260605-080000")
        self.assertEqual(path, "/etc/postfix/main.cf.ad-password-sentinel.20260605-080000.bak")

    def test_build_post_install_verification_commands_include_config_ldap_and_mail(self):
        commands = build_post_install_verification_commands("it-support@example.com")
        joined = "\n".join(" ".join(command) for command in commands)
        self.assertIn("--check-config", joined)
        self.assertIn("--check-ldap", joined)
        self.assertIn("--send-test-mail it-support@example.com", joined)

    def test_should_use_gum_requires_explicit_opt_in(self):
        self.assertFalse(should_use_gum(gum_present=True, user_requested=False))
        self.assertTrue(should_use_gum(gum_present=True, user_requested=True))
        self.assertFalse(should_use_gum(gum_present=False, user_requested=True))


if __name__ == "__main__":
    unittest.main()
