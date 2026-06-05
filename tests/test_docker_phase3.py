import unittest

from scripts.docker_helpers import build_container_cron_command, build_ldaps_ca_mount


class DockerPhase3Tests(unittest.TestCase):
    def test_build_container_cron_command_uses_flock_and_config_mount(self):
        command = build_container_cron_command()

        self.assertIn("flock -n /var/lock/ad-password-sentinel.lock", command)
        self.assertIn("--config /etc/ad-password-sentinel/config.env", command)
        self.assertIn("/opt/ad-password-sentinel/.venv/bin/python", command)

    def test_build_ldaps_ca_mount_maps_certificate_read_only(self):
        mount = build_ldaps_ca_mount("./certs/dc.crt")

        self.assertEqual(
            mount,
            "./certs/dc.crt:/usr/local/share/ca-certificates/ad-password-sentinel-dc.crt:ro",
        )


if __name__ == "__main__":
    unittest.main()
