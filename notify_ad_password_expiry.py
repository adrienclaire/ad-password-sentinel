#!/usr/bin/env python3

from datetime import datetime, timezone, timedelta
from email.message import EmailMessage
from email.utils import formatdate
from pathlib import Path
import argparse
import os
import re
import stat
import subprocess
import sys
import csv


APP_NAME = "AD Password Sentinel"
DEFAULT_CONFIG_PATH = "/etc/ad-password-sentinel/config.env"
DEFAULT_REPORT_DIR = "/var/log/ad-password-sentinel"
DEFAULT_REPORT_CSV = "ad-password-expiry-report.csv"
DEFAULT_SENDMAIL_PATH = "/usr/sbin/sendmail"

NEVER_EXPIRES_FILETIME = 9223372036854775807
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def load_env_file(path):
    config = {}

    with open(path, "r", encoding="utf-8") as file:
        for line in file:
            line = line.strip()

            if not line:
                continue

            if line.startswith("#"):
                continue

            if "=" not in line:
                continue

            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"').strip("'")

    return config


def get_required(config, key):
    value = config.get(key)

    if value is None or value == "":
        raise RuntimeError(f"Missing required config value: {key}")

    return value


def validate_no_header_control_chars(value, label):
    if "\r" in value or "\n" in value:
        raise RuntimeError(f"{label} must not contain line breaks")


def validate_email(value, label):
    validate_no_header_control_chars(value, label)

    if not EMAIL_RE.match(value):
        raise RuntimeError(f"{label} must be a valid email address")


def validate_config_file_permissions(path):
    if os.name == "nt":
        return

    config_path = Path(path)

    if not config_path.exists():
        raise RuntimeError(f"Config file does not exist: {config_path}")

    mode = stat.S_IMODE(config_path.stat().st_mode)

    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise RuntimeError(
            f"Config file permissions are too open: {config_path}. "
            "Use chmod 600 because it contains credentials."
        )


def validate_ldap_security(config):
    ad_server = get_required(config, "AD_SERVER")
    allow_insecure = parse_bool(config.get("ALLOW_INSECURE_LDAP", "false"))

    if ad_server.lower().startswith("ldap://") and not allow_insecure:
        raise RuntimeError(
            "AD_SERVER uses ldap://. Use ldaps:// or set ALLOW_INSECURE_LDAP=true "
            "only for a temporary test environment."
        )


def validate_sendmail_path(sendmail_path):
    path = Path(sendmail_path)

    if not path.is_absolute():
        raise RuntimeError("SENDMAIL_PATH must be an absolute path")

    if os.name != "nt" and path.exists():
        mode = path.stat().st_mode

        if mode & stat.S_IWOTH:
            raise RuntimeError(f"SENDMAIL_PATH is world-writable: {sendmail_path}")


def validate_mail_config(config):
    validate_email(get_required(config, "MAIL_FROM"), "MAIL_FROM")
    validate_email(get_required(config, "TECH_REPORT_TO"), "TECH_REPORT_TO")
    validate_no_header_control_chars(
        config.get("USER_MAIL_SUBJECT", "Your password will expire soon"),
        "USER_MAIL_SUBJECT"
    )
    validate_sendmail_path(config.get("SENDMAIL_PATH", DEFAULT_SENDMAIL_PATH))


def validate_config(config, config_path):
    validate_config_file_permissions(config_path)
    validate_ldap_security(config)
    validate_mail_config(config)


def parse_bool(value):
    return str(value).strip().lower() in ("true", "1", "yes", "y", "on")


def parse_notify_days(value):
    if value is None:
        return []

    value = value.strip()

    if value == "":
        return []

    return [int(item.strip()) for item in value.split(",") if item.strip()]


def parse_int(config, key, default, minimum=None):
    raw_value = config.get(key, str(default))

    try:
        value = int(raw_value)
    except ValueError as exc:
        raise RuntimeError(f"{key} must be an integer") from exc

    if minimum is not None and value < minimum:
        raise RuntimeError(f"{key} must be >= {minimum}")

    return value


def first_value(value):
    if isinstance(value, list):
        if len(value) == 0:
            return None
        return value[0]

    return value


def windows_filetime_to_datetime(value):
    value = first_value(value)

    if value is None:
        return None

    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    try:
        filetime = int(value)
    except Exception:
        return None

    if filetime <= 0:
        return None

    if filetime == NEVER_EXPIRES_FILETIME:
        return None

    return datetime(1601, 1, 1, tzinfo=timezone.utc) + timedelta(microseconds=filetime // 10)


def get_report_paths(config):
    report_dir = config.get("REPORT_DIR", DEFAULT_REPORT_DIR)
    report_csv = config.get("REPORT_CSV", DEFAULT_REPORT_CSV)

    report_dir_path = Path(report_dir)
    report_csv_path = Path(report_csv)

    if not report_csv_path.is_absolute():
        report_csv_path = report_dir_path / report_csv_path

    report_dir_resolved = report_dir_path.resolve()
    report_csv_resolved = report_csv_path.resolve()

    if report_dir_resolved not in report_csv_resolved.parents:
        raise RuntimeError("REPORT_CSV must be inside REPORT_DIR")

    return report_dir_path, report_csv_path


def send_local_mail(config, to_addr, subject, body):
    mail_from = get_required(config, "MAIL_FROM")
    test_mode = parse_bool(config.get("TEST_MODE", "true"))

    if not to_addr:
        raise RuntimeError("Cannot send mail without a recipient")

    validate_email(to_addr, "mail recipient")
    validate_no_header_control_chars(subject, "mail subject")

    if test_mode:
        print("")
        print("========== TEST MODE ==========")
        print(f"Would send mail from: {mail_from}")
        print(f"Would send mail to  : {to_addr}")
        print(f"Subject             : {subject}")
        print("---------- BODY ---------------")
        print(body)
        print("========== END TEST ===========")
        print("")
        return

    sendmail_path = config.get("SENDMAIL_PATH", DEFAULT_SENDMAIL_PATH)

    message = EmailMessage()
    message["From"] = mail_from
    message["To"] = to_addr
    message["Date"] = formatdate(localtime=True)
    message["Subject"] = subject
    message.set_content(body)

    process = subprocess.run(
        [sendmail_path, "-f", mail_from, "-t"],
        input=message.as_bytes(),
        capture_output=True,
        check=False,
        timeout=30
    )

    if process.returncode != 0:
        stderr = process.stderr.decode(errors="ignore")
        raise RuntimeError(f"sendmail failed: {stderr}")


def build_ldap_connection(config):
    from ldap3 import Connection, Server

    ad_server = get_required(config, "AD_SERVER")
    ad_bind_user = get_required(config, "AD_BIND_USER")
    ad_bind_password = get_required(config, "AD_BIND_PASSWORD")

    server = Server(ad_server, get_info=None, connect_timeout=10)

    connection = Connection(
        server,
        user=ad_bind_user,
        password=ad_bind_password,
        auto_bind=True
    )

    return connection


def get_expiring_users(config):
    from ldap3 import SUBTREE

    ad_base_dn = get_required(config, "AD_BASE_DN")
    warning_days = parse_int(config, "WARNING_DAYS", 14, minimum=0)
    notify_days = parse_notify_days(config.get("NOTIFY_DAYS", ""))

    now = datetime.now(timezone.utc)

    connection = build_ldap_connection(config)

    search_filter = (
        "(&"
        "(objectCategory=person)"
        "(objectClass=user)"
        "(!(userAccountControl:1.2.840.113556.1.4.803:=2))"
        "(!(userAccountControl:1.2.840.113556.1.4.803:=65536))"
        ")"
    )

    attributes = [
        "sAMAccountName",
        "displayName",
        "mail",
        "userPrincipalName",
        "msDS-UserPasswordExpiryTimeComputed"
    ]

    results = []

    try:
        entries = connection.extend.standard.paged_search(
            search_base=ad_base_dn,
            search_filter=search_filter,
            search_scope=SUBTREE,
            attributes=attributes,
            paged_size=500,
            generator=True
        )

        for entry in entries:
            if entry.get("type") != "searchResEntry":
                continue

            attrs = entry.get("attributes", {})

            sam = first_value(attrs.get("sAMAccountName"))
            display_name = first_value(attrs.get("displayName")) or sam
            mail = first_value(attrs.get("mail"))
            upn = first_value(attrs.get("userPrincipalName"))
            expiry_raw = attrs.get("msDS-UserPasswordExpiryTimeComputed")

            expiry_date = windows_filetime_to_datetime(expiry_raw)

            if expiry_date is None:
                continue

            days_left = (expiry_date.date() - now.date()).days

            if days_left < 0:
                status = "EXPIRED"
            elif days_left <= warning_days:
                status = "EXPIRING_SOON"
            else:
                continue

            if notify_days and days_left not in notify_days:
                continue

            results.append({
                "sam": sam,
                "display_name": display_name,
                "mail": mail,
                "upn": upn,
                "expiry_date": expiry_date,
                "days_left": days_left,
                "status": status
            })
    finally:
        connection.unbind()

    results.sort(key=lambda item: (item["days_left"], item["sam"] or ""))

    return results


def write_csv_report(config, results):
    report_dir, report_csv = get_report_paths(config)
    report_dir.mkdir(parents=True, exist_ok=True)

    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC

    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW

    fd = os.open(report_csv, flags, 0o600)

    with os.fdopen(fd, "w", newline="", encoding="utf-8") as csvfile:
        fieldnames = [
            "sam",
            "display_name",
            "mail",
            "upn",
            "expiry_date",
            "days_left",
            "status"
        ]

        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()

        for item in results:
            row = item.copy()
            row["expiry_date"] = item["expiry_date"].strftime("%Y-%m-%d %H:%M:%S UTC")
            writer.writerow(row)

    return report_csv


def build_tech_report_body(config, results, warning_days, report_csv):
    lines = []

    directory_label = config.get("DIRECTORY_LABEL", "Active Directory")

    lines.append(f"{APP_NAME} - password expiration report")
    lines.append("")
    lines.append(f"Directory: {directory_label}")
    lines.append(f"Seuil configuré : {warning_days} jour(s)")
    lines.append(f"Nombre de comptes concernés : {len(results)}")
    lines.append(f"CSV local : {report_csv}")
    lines.append("")

    if not results:
        lines.append("Aucun compte trouvé dans la fenêtre de notification.")
        return "\n".join(lines)

    lines.append("Comptes concernés :")
    lines.append("")

    for item in results:
        expiry_date = item["expiry_date"].strftime("%Y-%m-%d %H:%M")
        mail = item["mail"] or "NO_MAIL"
        display_name = item["display_name"] or ""
        sam = item["sam"] or ""
        status = item["status"]
        days_left = item["days_left"]

        lines.append(
            f"- {sam} | {display_name} | {mail} | {status} | "
            f"Jours restants: {days_left} | Expiration: {expiry_date}"
        )

    return "\n".join(lines)


def build_user_notification_body(item):
    display_name = item["display_name"] or item["sam"] or "user"
    expiry_date = item["expiry_date"].strftime("%Y-%m-%d")
    days_left = item["days_left"]

    lines = []
    lines.append(f"Hello {display_name},")
    lines.append("")

    if days_left < 0:
        lines.append("Your password has expired.")
    elif days_left == 0:
        lines.append("Your password expires today.")
    elif days_left == 1:
        lines.append("Your password expires tomorrow.")
    else:
        lines.append(f"Your password expires in {days_left} days.")

    lines.append(f"Expiration date: {expiry_date}")
    lines.append("")
    lines.append("Please change your password using your organization's standard procedure.")
    lines.append("If you need help, contact your IT support team.")

    return "\n".join(lines)


def notify_users(config, results):
    if not parse_bool(config.get("NOTIFY_USERS", "false")):
        return 0

    allowed_domains = [
        domain.strip().lower()
        for domain in config.get("USER_MAIL_ALLOWED_DOMAINS", "").split(",")
        if domain.strip()
    ]
    sent_count = 0

    for item in results:
        if item["days_left"] < 0:
            continue

        if not item["mail"]:
            print(f"[WARN] Skipping user without mail address: {item['sam']}")
            continue

        recipient_domain = item["mail"].split("@", 1)[-1].lower()

        if allowed_domains and recipient_domain not in allowed_domains:
            print(f"[WARN] Skipping user outside allowed mail domains: {item['sam']}")
            continue

        subject = config.get("USER_MAIL_SUBJECT", "Your password will expire soon")
        body = build_user_notification_body(item)
        send_local_mail(config, item["mail"], subject, body)
        sent_count += 1

    return sent_count


def parse_args(argv):
    parser = argparse.ArgumentParser(description=f"{APP_NAME} notification runner")
    parser.add_argument(
        "--config",
        default=os.environ.get("AD_PASSWORD_SENTINEL_CONFIG", DEFAULT_CONFIG_PATH),
        help=f"Path to config.env (default: {DEFAULT_CONFIG_PATH})"
    )

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv or sys.argv[1:])
    validate_config_file_permissions(args.config)
    config = load_env_file(args.config)
    validate_config(config, args.config)

    warning_days = parse_int(config, "WARNING_DAYS", 14, minimum=0)
    tech_report_to = get_required(config, "TECH_REPORT_TO")
    always_send_report = parse_bool(config.get("ALWAYS_SEND_REPORT", "true"))

    results = get_expiring_users(config)

    report_csv = write_csv_report(config, results)
    user_notifications = notify_users(config, results)

    print(f"[INFO] Accounts found: {len(results)}")
    print(f"[INFO] CSV report: {report_csv}")
    print(f"[INFO] User notifications sent: {user_notifications}")
    print(f"[INFO] Tech report recipient: {tech_report_to}")

    if results or always_send_report:
        subject = f"[{APP_NAME}] Password expiration report - {len(results)} account(s)"
        body = build_tech_report_body(config, results, warning_days, report_csv)
        send_local_mail(config, tech_report_to, subject, body)
    else:
        print("[INFO] No account found and ALWAYS_SEND_REPORT=false. No mail sent.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
