#!/usr/bin/env python3

from datetime import datetime, timezone, timedelta
from email.message import EmailMessage
from email.utils import formatdate
from pathlib import Path
import argparse
import errno
import smtplib
import os
import re
import ssl
import stat
import subprocess
import sys
import csv
from urllib.parse import urlsplit


APP_NAME = "AD Password Sentinel"
DEFAULT_CONFIG_PATH = "/etc/ad-password-sentinel/config.env"
DEFAULT_REPORT_DIR = "/var/log/ad-password-sentinel"
DEFAULT_REPORT_CSV = "ad-password-expiry-report.csv"
DEFAULT_SENDMAIL_PATH = "/usr/sbin/sendmail"
DEFAULT_LDAP_PORTS = {"ldap": 389, "ldaps": 636}

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

    disallowed = stat.S_IWGRP | stat.S_IXGRP | stat.S_IRWXO
    if mode & disallowed:
        raise RuntimeError(
            f"Config file permissions are too open: {config_path}. "
            "Use chmod 640 or chmod 600."
        )


def normalize_config(config):
    normalized = dict(config)
    legacy_server = normalized.get("AD_SERVER", "")

    if legacy_server and not normalized.get("LDAP_HOST"):
        parsed = urlsplit(
            legacy_server if "://" in legacy_server else f"ldaps://{legacy_server}"
        )
        normalized["LDAP_MODE"] = normalized.get("LDAP_MODE") or parsed.scheme.lower()
        normalized["LDAP_HOST"] = parsed.hostname or ""
        if parsed.port is not None:
            normalized["LDAP_PORT"] = str(parsed.port)

    aliases = {
        "LDAP_BASE_DN": "AD_BASE_DN",
        "LDAP_BIND_USER": "AD_BIND_USER",
    }
    for canonical, legacy in aliases.items():
        if not normalized.get(canonical) and normalized.get(legacy):
            normalized[canonical] = normalized[legacy]

    mode = normalized.get("LDAP_MODE", "ldaps").strip().lower()
    normalized["LDAP_MODE"] = mode
    normalized.setdefault("LDAP_PORT", str(DEFAULT_LDAP_PORTS.get(mode, 636)))
    normalized.setdefault("LDAP_TLS_VALIDATE", "true")
    normalized.setdefault("TEST_MODE", "true")

    if not normalized.get("SMTP_HOST") and normalized.get("SMTP_SERVER"):
        normalized["SMTP_HOST"] = normalized["SMTP_SERVER"]
    if not normalized.get("MAIL_TRANSPORT"):
        normalized["MAIL_TRANSPORT"] = (
            "smtp" if normalized.get("SMTP_HOST") else "sendmail"
        )
    normalized["MAIL_TRANSPORT"] = normalized["MAIL_TRANSPORT"].strip().lower()
    normalized.setdefault("SMTP_SECURITY", "starttls")
    return normalized


def get_ldap_url(config):
    normalized = normalize_config(config)
    host = get_required(normalized, "LDAP_HOST")
    port = parse_int(
        normalized,
        "LDAP_PORT",
        DEFAULT_LDAP_PORTS.get(normalized["LDAP_MODE"], 636),
        minimum=1,
    )
    return f"{normalized['LDAP_MODE']}://{host}:{port}"


def load_secret(path, label):
    secret_path = Path(path)
    if not secret_path.is_absolute():
        raise RuntimeError(f"{label} file path must be absolute")
    if not secret_path.is_file():
        raise RuntimeError(f"{label} file does not exist: {secret_path}")
    if os.name != "nt":
        mode = stat.S_IMODE(secret_path.stat().st_mode)
        disallowed = stat.S_IWGRP | stat.S_IXGRP | stat.S_IRWXO
        if mode & disallowed:
            raise RuntimeError(f"{label} file permissions are too open: {secret_path}")
    value = secret_path.read_text(encoding="utf-8").rstrip("\r\n")
    if not value:
        raise RuntimeError(f"{label} file is empty: {secret_path}")
    return value


def get_config_secret(config, file_key, legacy_key, label):
    if config.get(file_key):
        return load_secret(config[file_key], label)
    if config.get(legacy_key):
        if not parse_bool(config.get("TEST_MODE", "true")):
            raise RuntimeError(
                f"{file_key} is required in production; {legacy_key} is accepted only "
                "while TEST_MODE=true"
            )
        return config[legacy_key]
    raise RuntimeError(f"Missing required config value: {file_key}")


def validate_ldap_security(config):
    normalized = normalize_config(config)
    mode = normalized["LDAP_MODE"]
    if mode not in DEFAULT_LDAP_PORTS:
        raise RuntimeError("LDAP_MODE must be 'ldaps' or 'ldap'")

    allow_insecure = parse_bool_config(
        normalized, "ALLOW_INSECURE_LDAP", default=False
    )
    tls_validate = parse_bool_config(normalized, "LDAP_TLS_VALIDATE", default=True)
    if mode == "ldap" and not allow_insecure:
        raise RuntimeError(
            "LDAP_MODE=ldap is an insecure fallback. Set ALLOW_INSECURE_LDAP=true "
            "to explicitly accept the LDAP transport risk."
        )
    if mode == "ldaps" and not tls_validate and not allow_insecure:
        raise RuntimeError(
            "LDAP_TLS_VALIDATE=false requires ALLOW_INSECURE_LDAP=true"
        )
    if normalized.get("LDAP_CA_FILE") and not Path(normalized["LDAP_CA_FILE"]).is_file():
        raise RuntimeError(f"LDAP_CA_FILE does not exist: {normalized['LDAP_CA_FILE']}")


def validate_sendmail_path(sendmail_path):
    path = Path(sendmail_path)

    if not path.is_absolute():
        raise RuntimeError("SENDMAIL_PATH must be an absolute path")

    if os.name != "nt" and path.exists():
        mode = path.stat().st_mode

        if mode & stat.S_IWOTH:
            raise RuntimeError(f"SENDMAIL_PATH is world-writable: {sendmail_path}")


def validate_mail_config(config):
    normalized = normalize_config(config)
    validate_email(get_required(normalized, "MAIL_FROM"), "MAIL_FROM")
    validate_email(get_required(normalized, "TECH_REPORT_TO"), "TECH_REPORT_TO")
    validate_no_header_control_chars(
        normalized.get("USER_MAIL_SUBJECT", "Your password will expire soon"),
        "USER_MAIL_SUBJECT"
    )
    transport = normalized["MAIL_TRANSPORT"]
    if transport == "sendmail":
        validate_sendmail_path(normalized.get("SENDMAIL_PATH", DEFAULT_SENDMAIL_PATH))
    elif transport == "smtp":
        get_required(normalized, "SMTP_HOST")
        parse_int(normalized, "SMTP_PORT", 587, minimum=1)
        security = normalized.get("SMTP_SECURITY", "starttls").lower()
        if security not in ("none", "starttls", "ssl"):
            raise RuntimeError("SMTP_SECURITY must be 'none', 'starttls', or 'ssl'")
        if normalized.get("SMTP_USER"):
            if security == "none":
                raise RuntimeError(
                    "SMTP authentication requires SMTP_SECURITY=starttls or ssl"
                )
            get_config_secret(
                normalized, "SMTP_PASSWORD_FILE", "SMTP_PASSWORD", "SMTP password"
            )
    else:
        raise RuntimeError("MAIL_TRANSPORT must be 'smtp' or 'sendmail'")


def validate_config(config, config_path):
    validate_config_file_permissions(config_path)
    normalized = normalize_config(config)
    parse_bool_config(normalized, "TEST_MODE", default=True)
    validate_ldap_security(normalized)
    get_required(normalized, "LDAP_HOST")
    parse_int(normalized, "LDAP_PORT", 636, minimum=1)
    get_required(normalized, "LDAP_BASE_DN")
    get_required(normalized, "LDAP_BIND_USER")
    get_config_secret(
        normalized, "LDAP_PASSWORD_FILE", "AD_BIND_PASSWORD", "LDAP password"
    )
    validate_mail_config(normalized)


def parse_bool(value):
    return str(value).strip().lower() in ("true", "1", "yes", "y", "on")


def parse_bool_config(config, key, default=False):
    raw_value = config.get(key)
    if raw_value is None or str(raw_value).strip() == "":
        return default
    normalized = str(raw_value).strip().lower()
    if normalized in ("true", "1", "yes", "y", "on"):
        return True
    if normalized in ("false", "0", "no", "n", "off"):
        return False
    raise RuntimeError(f"{key} must be a boolean")


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
    config = normalize_config(config)
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

    message = EmailMessage()
    message["From"] = mail_from
    message["To"] = to_addr
    message["Date"] = formatdate(localtime=True)
    message["Subject"] = subject
    message.set_content(body)

    if config["MAIL_TRANSPORT"] == "smtp":
        send_smtp_mail(config, message)
        return

    sendmail_path = config.get("SENDMAIL_PATH", DEFAULT_SENDMAIL_PATH)
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


def send_smtp_mail(config, message):
    host = get_required(config, "SMTP_HOST")
    port = parse_int(config, "SMTP_PORT", 587, minimum=1)
    security = config.get("SMTP_SECURITY", "starttls").lower()
    context = ssl.create_default_context()
    if security == "ssl":
        client_context = smtplib.SMTP_SSL(
            host, port, timeout=30, context=context
        )
    else:
        client_context = smtplib.SMTP(host, port, timeout=30)

    with client_context as client:
        if security == "starttls":
            client.starttls(context=context)
        if config.get("SMTP_USER"):
            if security == "none":
                raise RuntimeError(
                    "SMTP authentication requires SMTP_SECURITY=starttls or ssl"
                )
            password = get_config_secret(
                config, "SMTP_PASSWORD_FILE", "SMTP_PASSWORD", "SMTP password"
            )
            client.login(config["SMTP_USER"], password)
        client.send_message(message)


def build_ldap_connection(config):
    from ldap3 import Connection, Server, Tls

    config = normalize_config(config)
    host = get_required(config, "LDAP_HOST")
    port = parse_int(config, "LDAP_PORT", 636, minimum=1)
    bind_user = get_required(config, "LDAP_BIND_USER")
    bind_password = get_config_secret(
        config, "LDAP_PASSWORD_FILE", "AD_BIND_PASSWORD", "LDAP password"
    )
    use_ssl = config["LDAP_MODE"] == "ldaps"
    tls = None
    if use_ssl:
        tls = Tls(
            validate=(
                ssl.CERT_REQUIRED
                if parse_bool(config.get("LDAP_TLS_VALIDATE", "true"))
                else ssl.CERT_NONE
            ),
            ca_certs_file=config.get("LDAP_CA_FILE") or None,
        )

    server = Server(
        host,
        port=port,
        use_ssl=use_ssl,
        tls=tls,
        get_info=None,
        connect_timeout=10,
    )

    connection = Connection(
        server,
        user=bind_user,
        password=bind_password,
        auto_bind=False,
        raise_exceptions=True,
    )
    connection.open()
    connection.bind()

    return connection


def safe_ldap_unbind(connection):
    try:
        connection.unbind()
    except OSError as exc:
        if exc.errno not in {
            104,
            54,
            errno.ECONNRESET,
            errno.ECONNABORTED,
            10053,
            10054,
        }:
            raise
    except Exception as exc:
        if exc.__class__.__name__ not in {
            "LDAPSocketReceiveError",
            "LDAPSessionTerminatedByServerError",
        }:
            raise


def get_expiring_users(config):
    from ldap3 import SUBTREE

    config = normalize_config(config)
    ad_base_dn = get_required(config, "LDAP_BASE_DN")
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
        safe_ldap_unbind(connection)

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
    parser.add_argument(
        "--check-config",
        action="store_true",
        help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--check-ldap",
        action="store_true",
        help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--send-test-mail",
        metavar="EMAIL",
        help=argparse.SUPPRESS
    )
    subparsers = parser.add_subparsers(dest="command")

    def add_command(name, help_text):
        command_parser = subparsers.add_parser(name, help=help_text)
        command_parser.add_argument(
            "--config",
            default=argparse.SUPPRESS,
            help="Path to config.env",
        )
        return command_parser

    add_command("validate", "Validate configuration and exit")
    add_command("check-ldap", "Validate configuration and bind to LDAP")
    check_mail_parser = add_command(
        "check-mail", "Process a test message using the configured mail transport"
    )
    check_mail_parser.add_argument(
        "--to", dest="mail_to", help="Recipient (defaults to TECH_REPORT_TO)"
    )
    add_command("run", "Run the password expiration workflow")

    args = parser.parse_args(argv)
    if args.check_config:
        args.command = "validate"
    elif args.check_ldap:
        args.command = "check-ldap"
    elif args.send_test_mail:
        args.command = "check-mail"
        args.mail_to = args.send_test_mail
    elif args.command is None:
        args.command = "run"
    if not hasattr(args, "mail_to"):
        args.mail_to = None
    return args


def load_and_validate_config(config_path):
    validate_config_file_permissions(config_path)
    config = normalize_config(load_env_file(config_path))
    validate_config(config, config_path)
    return config


def check_ldap(config):
    connection = build_ldap_connection(config)
    safe_ldap_unbind(connection)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    config = load_and_validate_config(args.config)

    if args.command == "validate":
        print("[OK] Configuration is valid.")
        return

    if args.command == "check-ldap":
        check_ldap(config)
        print("[OK] LDAP bind succeeded.")
        return

    if args.command == "check-mail":
        recipient = args.mail_to or get_required(config, "TECH_REPORT_TO")
        send_local_mail(
            config,
            recipient,
            f"[{APP_NAME}] Test email",
            "AD Password Sentinel test email."
        )
        print(f"[OK] Test email processed for {recipient}.")
        return

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
