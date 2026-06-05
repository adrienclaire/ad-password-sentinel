#!/usr/bin/env python3

from getpass import getpass
from pathlib import Path
from urllib.parse import urlparse
import os
import shutil
import socket
import subprocess
import sys


APP_NAME = "AD Password Sentinel"
INSTALL_DIR = Path("/opt/ad-password-sentinel")
CONFIG_DIR = Path("/etc/ad-password-sentinel")
CONFIG_PATH = CONFIG_DIR / "config.env"
LOG_DIR = Path("/var/log/ad-password-sentinel")
SCRIPT_NAME = "notify_ad_password_expiry.py"
PROJECT_DIR = Path(__file__).resolve().parent
LOCK_PATH = Path("/var/lock/ad-password-sentinel.lock")


def gum_available():
    return command_exists("gum")


def plain_prompt(label, default=None, secret=False):
    suffix = f" [{default}]" if default else ""
    question = f"{label}{suffix}: "
    value = getpass(question) if secret else input(question)
    value = value.strip()
    return value if value else default


def plain_yes_no(label, default=False):
    default_label = "Y/n" if default else "y/N"
    value = input(f"{label} [{default_label}]: ").strip().lower()

    if not value:
        return default

    return value in ("y", "yes")


def plain_choose(label, choices, default=None):
    print(label)

    for index, choice in enumerate(choices, start=1):
        marker = " (default)" if choice == default else ""
        print(f"{index}. {choice}{marker}")

    raw_value = plain_prompt("Choose", str(choices.index(default) + 1) if default in choices else "1")

    try:
        index = int(raw_value) - 1
    except ValueError:
        return default or choices[0]

    if 0 <= index < len(choices):
        return choices[index]

    return default or choices[0]


def gum_input(label, default=None, secret=False):
    command = ["gum", "input", "--prompt", f"{label}: "]

    if default:
        command.extend(["--value", default])

    if secret:
        command.append("--password")

    result = subprocess.run(command, text=True, capture_output=True, check=False)

    if result.returncode != 0:
        return plain_prompt(label, default, secret)

    value = result.stdout.strip()
    return value if value else default


def gum_confirm(label, default=False):
    command = ["gum", "confirm", label]

    if default:
        command.append("--default=true")

    result = subprocess.run(command, check=False)

    if result.returncode in (0, 1):
        return result.returncode == 0

    return plain_yes_no(label, default)


def gum_choose(label, choices, default=None):
    print(label)
    command = ["gum", "choose"]
    command.extend(choices)
    result = subprocess.run(command, text=True, capture_output=True, check=False)

    if result.returncode != 0:
        return plain_choose(label, choices, default)

    value = result.stdout.strip()
    return value if value else default


def prompt(label, default=None, secret=False):
    if gum_available():
        return gum_input(label, default, secret)

    return plain_prompt(label, default, secret)


def yes_no(label, default=False):
    if gum_available():
        return gum_confirm(label, default)

    return plain_yes_no(label, default)


def choose(label, choices, default=None):
    if gum_available():
        return gum_choose(label, choices, default)

    return plain_choose(label, choices, default)


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
        "daily": "0 8 * * *",
        "weekly": "0 8 * * 1",
        "three-times-weekly": "0 8 * * 1,3,5",
    }
    return schedules.get(choice, schedules["1"])


def build_cron_command(expression):
    script_path = (INSTALL_DIR / SCRIPT_NAME).as_posix()
    return (
        f"{expression} root /usr/bin/flock -n {LOCK_PATH.as_posix()} "
        f"/usr/bin/env python3 {script_path} --config {CONFIG_PATH.as_posix()}"
    )


def ldap_port_from_server(ad_server):
    parsed = urlparse(ad_server)

    if parsed.scheme not in ("ldap", "ldaps"):
        raise RuntimeError("AD_SERVER must start with ldap:// or ldaps://")

    if not parsed.hostname:
        raise RuntimeError("AD_SERVER must include a hostname")

    default_port = 636 if parsed.scheme == "ldaps" else 389
    return parsed.hostname, parsed.port or default_port


def can_connect(host, port, timeout=5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def build_postfix_relay_commands(relay_host, relay_port, smtp_user="", smtp_password="", use_tls=True):
    relay = f"[{relay_host}]:{relay_port}"
    commands = [
        ["postconf", "-e", f"relayhost={relay}"],
        ["postconf", "-e", "smtp_tls_security_level=may" if use_tls else "smtp_tls_security_level=none"],
        ["postconf", "-e", f"smtp_use_tls={'yes' if use_tls else 'no'}"],
    ]

    if smtp_user:
        commands.extend([
            ["postconf", "-e", "smtp_sasl_auth_enable=yes"],
            ["postconf", "-e", "smtp_sasl_security_options=noanonymous"],
            ["postconf", "-e", "smtp_sasl_password_maps=hash:/etc/postfix/sasl_passwd"],
        ])

    return commands


def configure_postfix_relay():
    relay_host = prompt("SMTP relay host", "smtp.example.com")
    relay_port = prompt("SMTP relay port", "587")
    use_tls = yes_no("Use TLS for SMTP relay", True)
    smtp_user = prompt("SMTP auth username, blank for no auth", "")
    smtp_password = ""

    if smtp_user:
        smtp_password = prompt("SMTP auth password", secret=True)

    for command in build_postfix_relay_commands(relay_host, relay_port, smtp_user, smtp_password, use_tls):
        run(command)

    if smtp_user:
        sasl_path = Path("/etc/postfix/sasl_passwd")
        fd = os.open(sasl_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)

        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(f"[{relay_host}]:{relay_port} {smtp_user}:{smtp_password}\n")

        run(["chmod", "600", str(sasl_path)])
        run(["postmap", str(sasl_path)])

    if command_exists("systemctl"):
        run(["systemctl", "restart", "postfix"])
    else:
        run(["service", "postfix", "restart"])


def choose_ldap_settings():
    mode = choose(
        "LDAP transport",
        [
            "LDAP fallback on 389",
            "LDAPS on 636",
            "Custom LDAP URL",
        ],
        "LDAP fallback on 389",
    )

    if mode == "LDAPS on 636":
        ad_server = prompt("AD LDAPS server", "ldaps://dc01.example.local:636")
        allow_insecure = "false"
    elif mode == "Custom LDAP URL":
        ad_server = prompt("AD LDAP URL", "ldap://dc01.example.local:389")
        allow_insecure = "true" if ad_server.lower().startswith("ldap://") else "false"
    else:
        ad_server = prompt("AD LDAP server", "ldap://dc01.example.local:389")
        allow_insecure = "true"

    host, port = ldap_port_from_server(ad_server)

    if can_connect(host, port):
        print(f"LDAP TCP check succeeded: {host}:{port}")
    else:
        print(f"LDAP TCP check failed or timed out: {host}:{port}")
        print("You can still install, but run --check-ldap after fixing network or certificate issues.")

    return ad_server, allow_insecure


def build_config():
    print("")
    print("Configuration")
    print("Keep TEST_MODE=true until you validate LDAP search and mail delivery.")

    ad_server, allow_insecure = choose_ldap_settings()

    values = {
        "AD_SERVER": ad_server,
        "ALLOW_INSECURE_LDAP": allow_insecure,
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
    choice = choose(
        "Cron schedule",
        [
            "daily",
            "weekly",
            "three-times-weekly",
        ],
        "daily",
    )
    expression = cron_expression(choice)

    command = build_cron_command(expression)
    cron_path = Path("/etc/cron.d/ad-password-sentinel")
    cron_path.write_text(command + "\n", encoding="utf-8")
    run(["chmod", "644", str(cron_path)])
    print(f"Cron installed: {command}")


def main():
    require_linux()
    require_root()

    print(APP_NAME)
    print("Linux installer")

    mail_mode = choose(
        "Mail transport",
        [
            "Use existing sendmail/Postfix",
            "Install Postfix",
            "Configure Postfix SMTP relay",
            "Skip mail setup",
        ],
        "Use existing sendmail/Postfix",
    )

    if mail_mode == "Use existing sendmail/Postfix" and (command_exists("postfix") or Path("/usr/sbin/sendmail").exists()):
        print("Local mail transport found.")
    elif mail_mode == "Install Postfix":
        install_postfix()
    elif mail_mode == "Configure Postfix SMTP relay":
        if not command_exists("postfix"):
            install_postfix()
        configure_postfix_relay()
    else:
        print("Postfix skipped. Keep TEST_MODE=true until mail transport is configured.")

    install_files()
    configure_cron()

    print("")
    print("Installed.")
    print(f"Edit config: {CONFIG_PATH}")
    print(f"Run test: python3 {INSTALL_DIR / SCRIPT_NAME} --config {CONFIG_PATH}")
    print(f"Check config: python3 {INSTALL_DIR / SCRIPT_NAME} --config {CONFIG_PATH} --check-config")
    print(f"Check LDAP: python3 {INSTALL_DIR / SCRIPT_NAME} --config {CONFIG_PATH} --check-ldap")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
