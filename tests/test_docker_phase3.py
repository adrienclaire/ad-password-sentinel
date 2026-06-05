import unittest

from scripts.docker_helpers import build_container_cron_command


class DockerPhase3Tests(unittest.TestCase):
    def test_build_container_cron_command_uses_flock_and_config_mount(self):
        command = build_container_cron_command()

        self.assertIn("flock -n /var/lock/ad-password-sentinel.lock", command)
        self.assertIn("--config /etc/ad-password-sentinel/config.env", command)
        self.assertIn("/opt/ad-password-sentinel/.venv/bin/python", command)


if __name__ == "__main__":
    unittest.main()
