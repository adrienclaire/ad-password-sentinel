#!/usr/bin/env python3

from getpass import getpass
from pathlib import Path
import shutil
import subprocess
import sys


APP_NAME = "AD Password Sentinel"
INSTALL_DIR = Path("/opt/ad-password-sentinel")
CONFIG_DIR = Path("/etc/ad-password-sentinel")
CONFIG_PATH = CONFIG_DIR / "config.env"
LOG_DIR = Path("/var/log/ad-password-sentinel")
SCRIPT_NAME = "notify_ad_password_expiry.py"
PROJECT_DIR = Path(__file__).resolve().parent


def prompt(label, default=None, secret=False):
    suffix = f" [{default}]" if default else ""
    question = f"{label}{suffix}: "
    value = getpass(question) if secret else input(question)
    value = value.strip()
    return value if value else default


def yes_no(label, default=False):
    default_label = "Y/n" if default else "y/N"
    value = input(f"{label} [{default_label}]: ").strip().lower()

    if not value:
        return default

    return value in ("y", "yes")


def require_linux():
    if sys.platform.startswith("linux"):
        return

    raise RuntimeError("This installer is for Linux hosts. Use manual setup on other systems.")


def require_root():
    if hasattr(Path, "home") and Path.home() == Path("/root"):
        return

    try:
        import os

        if os.geteuid() == 0:
            return
    except AttributeError:
        pass

    raise RuntimeError("Run this installer as root so it can write /opt, /etc, /var/log, and cron.")


def command_exists(command):
    return shutil.which(command) is not None


def run(command):
    subprocess.run(command, check=True)


def detect_package_manager():
    for manager in ("apt-get", "dnf", "yum"):
        if command_exists(manager):
            return manager

    return None


def install_postfix():
    manager = detect_package_manager()

    if manager is None:
        print("No supported package manager found. Install Postfix manually, then rerun setup.")
        return

    if manager == "apt-get":
        run(["apt-get", "update"])
        run(["apt-get", "install", "-y", "postfix"])
        return

    run([manager, "install", "-y", "postfix"])
    run(["systemctl", "enable", "--now", "postfix"])


def cron_expression(choice):
    schedules = {
        "1": "0 8 * * *",
        "2": "0 8 * * 1",
        "3": "0 8 * * 1,3,5",
    }
    return schedules.get(choice, schedules["1"])


def build_config():
    print("")
    print("Configuration")
    print("Keep TEST_MODE=true until you validate LDAP search and mail delivery.")

    values = {
        "AD_SERVER": prompt("AD LDAP server", "ldaps://dc01.example.local:636"),
        "ALLOW_INSECURE_LDAP": "true" if yes_no("Allow insecure ldap:// without TLS", False) else "false",
        "AD_BASE_DN": prompt("AD base DN", "DC=example,DC=local"),
        "AD_BIND_USER": prompt("AD bind user", "svc_ad_password_sentinel@example.local"),
        "AD_BIND_PASSWORD": prompt("AD bind password", secret=True),
        "DIRECTORY_LABEL": prompt("Directory label", "Example Active Directory"),
        "WARNING_DAYS": prompt("Warning window in days", "14"),
        "NOTIFY_DAYS": prompt("Notification days", "14,7,3,1,0"),
        "NOTIFY_USERS": "true" if yes_no("Notify end users", False) else "false",
        "USER_MAIL_ALLOWED_DOMAINS": prompt("Allowed user mail domains", "example.com"),
        "MAIL_FROM": prompt("Sender email", "noreply@example.com"),
        "TECH_REPORT_TO": prompt("Tech report recipient", "it-support@example.com"),
        "USER_MAIL_SUBJECT": prompt("User email subject", "Your password will expire soon"),
        "TEST_MODE": "true",
        "ALWAYS_SEND_REPORT": "true",
        "SENDMAIL_PATH": prompt("sendmail path", "/usr/sbin/sendmail"),
        "REPORT_DIR": str(LOG_DIR),
        "REPORT_CSV": "ad-password-expiry-report.csv",
    }

    lines = [f"{key}={value}" for key, value in values.items()]
    return "\n".join(lines) + "\n"


def install_files():
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    shutil.copy2(PROJECT_DIR / SCRIPT_NAME, INSTALL_DIR / SCRIPT_NAME)
    (CONFIG_PATH).write_text(build_config(), encoding="utf-8")

    run(["chmod", "750", str(INSTALL_DIR)])
    run(["chmod", "750", str(LOG_DIR)])
    run(["chmod", "600", str(CONFIG_PATH)])
    run(["chmod", "755", str(INSTALL_DIR / SCRIPT_NAME)])

    if command_exists("chown"):
        run(["chown", "root:root", str(INSTALL_DIR / SCRIPT_NAME), str(CONFIG_PATH)])


def configure_cron():
    print("")
    print("Cron schedule")
    print("1. Every day at 08:00 (recommended)")
    print("2. Every Monday at 08:00")
    print("3. Monday, Wednesday, Friday at 08:00")
    choice = prompt("Choose schedule", "1")
    expression = cron_expression(choice)

    command = f"{expression} root /usr/bin/env python3 {INSTALL_DIR / SCRIPT_NAME} --config {CONFIG_PATH}"
    cron_path = Path("/etc/cron.d/ad-password-sentinel")
    cron_path.write_text(command + "\n", encoding="utf-8")
    run(["chmod", "644", str(cron_path)])
    print(f"Cron installed: {command}")


def main():
    require_linux()
    require_root()

    print(APP_NAME)
    print("Linux installer")

    if command_exists("postfix") or Path("/usr/sbin/sendmail").exists():
        print("Local mail transport found.")
    elif yes_no("Postfix/sendmail was not found. Install Postfix now", False):
        install_postfix()
    else:
        print("Postfix skipped. Keep TEST_MODE=true until mail transport is configured.")

    install_files()
    configure_cron()

    print("")
    print("Installed.")
    print(f"Edit config: {CONFIG_PATH}")
    print(f"Run test: python3 {INSTALL_DIR / SCRIPT_NAME} --config {CONFIG_PATH}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
