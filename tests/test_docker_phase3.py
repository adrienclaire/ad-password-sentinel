from pathlib import Path
import unittest


class DockerPhase3Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[1]

    def test_compose_is_one_shot_non_root_and_read_only(self):
        compose = (self.root / "docker-compose.yml").read_text(encoding="utf-8")

        self.assertIn("read_only: true", compose)
        self.assertIn(
            'user: "${CONTAINER_UID:-10001}:${CONTAINER_GID:-10001}"',
            compose,
        )
        self.assertIn("restart: \"no\"", compose)
        self.assertIn("cap_drop:", compose)
        self.assertIn("- ALL", compose)
        self.assertIn("no-new-privileges:true", compose)
        self.assertIn("TZ:", compose)
        self.assertIn("extra_hosts:", compose)
        self.assertIn("${LDAP_HOST:-dc.invalid}:${LDAP_IP:-127.0.0.1}", compose)
        self.assertIn("uid=${CONTAINER_UID:-10001}", compose)
        self.assertNotIn("postfix", compose.lower())

    def test_compose_mounts_inputs_read_only_and_reports_writable(self):
        compose = (self.root / "docker-compose.yml").read_text(encoding="utf-8")

        self.assertIn("/etc/ad-password-sentinel/config.env:ro", compose)
        self.assertIn("/run/secrets/ldap-password:ro", compose)
        self.assertIn("/run/certs/ad-password-sentinel-ca.crt:ro", compose)
        self.assertIn("/var/log/ad-password-sentinel:rw", compose)

    def test_dockerfile_runs_as_unprivileged_user_without_mail_daemon(self):
        dockerfile = (self.root / "Dockerfile").read_text(encoding="utf-8")

        self.assertIn("USER 10001:10001", dockerfile)
        self.assertIn("tzdata", dockerfile)
        self.assertNotIn("postfix", dockerfile.lower())
        self.assertNotIn(" cron ", dockerfile.lower())

    def test_entrypoint_is_one_shot_and_logs_to_stdout(self):
        entrypoint = (self.root / "docker" / "entrypoint.sh").read_text(encoding="utf-8")

        self.assertIn('exec "$PYTHON"', entrypoint)
        self.assertIn('"$APPLICATION" run --config "$RUNTIME_CONFIG"', entrypoint)
        self.assertIn('"$APPLICATION" validate --config "$RUNTIME_CONFIG"', entrypoint)
        self.assertIn('"$APPLICATION" check-ldap --config "$RUNTIME_CONFIG"', entrypoint)
        self.assertIn(
            '"$APPLICATION" check-mail --config "$RUNTIME_CONFIG" --to "$1"',
            entrypoint,
        )
        self.assertNotIn("cron -f", entrypoint)
        self.assertNotIn("cron.log", entrypoint)

    def test_host_setup_wrappers_exist_and_keep_test_mode(self):
        for relative_path in ("docker/setup.sh", "docker/setup.ps1"):
            content = (self.root / relative_path).read_text(encoding="utf-8")
            self.assertIn("TEST_MODE=true", content)
            self.assertIn("MAIL_TRANSPORT=smtp", content)
            self.assertIn("LDAP_PASSWORD_FILE=/run/secrets/ldap-password", content)
            self.assertIn("validate", content)
            self.assertIn("check-ldap", content)
            self.assertIn("CA certificate", content)
            self.assertIn("DNS", content)

    def test_host_setup_wrappers_do_not_schedule_from_mutable_checkout(self):
        shell_setup = (self.root / "docker" / "setup.sh").read_text(encoding="utf-8")
        powershell_setup = (self.root / "docker" / "setup.ps1").read_text(encoding="utf-8")
        crontab = (self.root / "docker" / "crontab").read_text(encoding="utf-8")

        self.assertIn("/usr/bin/docker run --rm --read-only", shell_setup)
        self.assertNotIn("cd %q && /usr/bin/docker compose run", shell_setup)
        self.assertIn('schtasks /Create /SC DAILY /ST 08:00', powershell_setup)
        self.assertIn('docker $DockerArgs', powershell_setup)
        self.assertIn("Do not schedule Docker runs from a mutable source checkout", crontab)

    def test_windows_setup_hardens_parent_directories(self):
        powershell_setup = (self.root / "docker" / "setup.ps1").read_text(encoding="utf-8")

        self.assertIn('@("config", "secrets", "certs")', powershell_setup)
        self.assertIn('SYSTEM:(OI)(CI)(F)', powershell_setup)


if __name__ == "__main__":
    unittest.main()
