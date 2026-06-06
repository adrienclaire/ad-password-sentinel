#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AD Password Sentinel"
SERVICE_USER="ad-password-sentinel"
SCRIPT_NAME="notify_ad_password_expiry.py"
DRY_RUN=0
INSTALLER_TEST_MODE=0
UI_MODE="${ADPS_UI:-auto}"
ADPS_ROOT="${ADPS_ROOT:-}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

root_path() {
  printf '%s%s' "$ADPS_ROOT" "$1"
}

INSTALL_DIR="$(root_path /opt/ad-password-sentinel)"
CONFIG_DIR="$(root_path /etc/ad-password-sentinel)"
CONFIG_PATH="$CONFIG_DIR/config.env"
LDAP_SECRET_PATH="$CONFIG_DIR/ldap-password"
SMTP_SECRET_PATH="$CONFIG_DIR/smtp-password"
LOG_DIR="$(root_path /var/log/ad-password-sentinel)"
LOCK_PATH="$LOG_DIR/ad-password-sentinel.lock"
CRON_PATH="$(root_path /etc/cron.d/ad-password-sentinel)"
LDAP_CA_PATH="$CONFIG_DIR/ldap-ca.crt"
VENV_DIR="$INSTALL_DIR/.venv"
RUNTIME_PATH="$INSTALL_DIR/$SCRIPT_NAME"
CONFIG_CONTENT=""

usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [--dry-run] [--ui auto|whiptail|plain] [--test-mode]

  --dry-run    Show actions and run the questionnaire without changing files.
  --ui         Use whiptail when usable (default), or force plain prompts.
  --test-mode  Permit a test root and fake system commands. No production use.
EOF
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

quote_command() {
  printf '%q ' "$@"
}

run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] '
    quote_command "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_root() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] '
    quote_command "$@"
    printf '\n'
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@" < /dev/tty > /dev/tty 2> /dev/tty
  fi
}

run_interactive() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] interactive: '
    quote_command "$@"
    printf '\n'
    return 0
  fi
  [ -r /dev/tty ] && [ -w /dev/tty ] || die "A usable /dev/tty is required for: $*"
  if [ "$(id -u)" -eq 0 ]; then
    "$@" < /dev/tty > /dev/tty 2> /dev/tty
  else
    sudo "$@" < /dev/tty > /dev/tty 2> /dev/tty
  fi
}

ui_can_prompt() {
  [ -r /dev/tty ] && [ -w /dev/tty ] && [ "${TERM:-dumb}" != "dumb" ]
}

whiptail_usable() {
  [ "$UI_MODE" != "plain" ] &&
    command -v whiptail >/dev/null 2>&1 &&
    ui_can_prompt
}

plain_input() {
  local prompt="$1"
  local default="${2:-}"
  local secret="${3:-0}"
  local answer=""
  local suffix=""

  [ -n "$default" ] && suffix=" [$default]"
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s%s: ' "$prompt" "$suffix" > /dev/tty
    if [ "$secret" -eq 1 ]; then
      stty -echo < /dev/tty 2>/dev/null || true
      IFS= read -r answer < /dev/tty || answer=""
      stty echo < /dev/tty 2>/dev/null || true
      printf '\n' > /dev/tty
    else
      IFS= read -r answer < /dev/tty || answer=""
    fi
  else
    printf '%s%s: ' "$prompt" "$suffix" >&2
    IFS= read -r answer || answer=""
  fi
  printf '%s' "${answer:-$default}"
}

ui_input() {
  local prompt="$1"
  local default="${2:-}"
  local secret="${3:-0}"
  local value=""
  local box="--inputbox"

  if whiptail_usable; then
    [ "$secret" -eq 0 ] || box="--passwordbox"
    value="$(
      whiptail --title "$APP_NAME" "$box" "$prompt" 10 76 "$default" \
        --output-fd 3 3>&1 1>/dev/tty 2>/dev/tty
    )" || return 1
    printf '%s' "${value:-$default}"
    return
  fi
  plain_input "$prompt" "$default" "$secret"
}

ui_yes_no() {
  local prompt="$1"
  local default="${2:-yes}"
  local answer=""
  local default_arg=()

  if whiptail_usable; then
    [ "$default" = "yes" ] || default_arg=(--defaultno)
    whiptail --title "$APP_NAME" "${default_arg[@]}" --yesno "$prompt" 10 76 \
      < /dev/tty > /dev/tty 2> /dev/tty
    return
  fi

  while true; do
    if [ "$default" = "yes" ]; then
      answer="$(plain_input "$prompt [Y/n]")"
    else
      answer="$(plain_input "$prompt [y/N]")"
    fi
    answer="${answer,,}"
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      "") [ "$default" = "yes" ]; return ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

ui_menu() {
  local prompt="$1"
  local default="$2"
  shift 2
  local choice=""
  local tag
  local description

  if whiptail_usable; then
    choice="$(
      whiptail --title "$APP_NAME" --default-item "$default" --output-fd 3 \
        --menu "$prompt" 18 78 10 "$@" 3>&1 1>/dev/tty 2>/dev/tty
    )" || return 1
    printf '%s' "$choice"
    return
  fi

  if [ -w /dev/tty ]; then
    printf '%s\n' "$prompt" > /dev/tty
  else
    printf '%s\n' "$prompt" >&2
  fi
  while [ "$#" -gt 0 ]; do
    tag="$1"
    description="$2"
    shift 2
    if [ -w /dev/tty ]; then
      printf '  %s) %s%s\n' "$tag" "$description" "$([ "$tag" = "$default" ] && printf ' (recommended)')" > /dev/tty
    else
      printf '  %s) %s%s\n' "$tag" "$description" "$([ "$tag" = "$default" ] && printf ' (recommended)')" >&2
    fi
  done
  choice="$(plain_input "Choose" "$default")"
  printf '%s' "$choice"
}

domain_from_fqdn() {
  local fqdn="${1%.}"
  case "$fqdn" in
    *.*) printf '%s' "${fqdn#*.}" ;;
    *) return 1 ;;
  esac
}

base_dn_from_domain() {
  local domain="${1%.}"
  local part
  local result=""
  local old_ifs="$IFS"
  IFS='.'
  for part in $domain; do
    [ -n "$part" ] || continue
    if [ -n "$result" ]; then
      result="$result,DC=$part"
    else
      result="DC=$part"
    fi
  done
  IFS="$old_ifs"
  printf '%s' "$result"
}

bind_upn() {
  printf '%s@%s' "$1" "$2"
}

cron_expression() {
  case "$1" in
    daily|1) printf '0 8 * * *' ;;
    weekly|2) printf '0 8 * * 1' ;;
    weekdays|three-times-weekly|3) printf '0 8 * * 1,3,5' ;;
    *) return 1 ;;
  esac
}

venv_package_candidates() {
  local version="$1"
  printf 'python%s-venv\npython3-venv\n' "$version"
}

valid_fqdn() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

valid_ipv4() {
  local ip="$1"
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
  ' <<<"$ip"
}

config_value() {
  local key="$1"
  if [ -f "$CONFIG_PATH" ]; then
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_PATH"
    return
  fi
  [ -n "$CONFIG_CONTENT" ] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' <<<"$CONFIG_CONTENT"
}

write_secure_file() {
  local path="$1"
  local content="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would write secret file $path with mode 0640"
    return
  fi
  umask 077
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod 640 "$path"
}

write_config_file() {
  local content="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would write $CONFIG_PATH with mode 0640"
    printf '%s\n' "$content"
    return
  fi
  umask 077
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$content" > "$CONFIG_PATH"
  chmod 640 "$CONFIG_PATH"
}

set_config_value() {
  local key="$1"
  local value="$2"
  local tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would set $key=$value in $CONFIG_PATH"
    if grep -q "^${key}=" <<<"$CONFIG_CONTENT"; then
      CONFIG_CONTENT="$(awk -F= -v key="$key" -v value="$value" '$1 == key { print key "=" value; next } { print }' <<<"$CONFIG_CONTENT")"
    else
      CONFIG_CONTENT="${CONFIG_CONTENT}"$'\n'"$key=$value"
    fi
    return
  fi
  tmp="${CONFIG_PATH}.tmp.$$"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    $1 == key { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$CONFIG_PATH" > "$tmp"
  chmod 640 "$tmp"
  mv "$tmp" "$CONFIG_PATH"
}

detect_python_minor() {
  python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

detect_package_manager() {
  local manager
  for manager in apt-get dnf yum apk; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s' "$manager"
      return
    fi
  done
  return 1
}

install_venv_package() {
  local version="$1"
  local manager
  local package
  manager="$(detect_package_manager)" || die "No supported package manager found."

  case "$manager" in
    apt-get)
      run_root apt-get update
      while IFS= read -r package; do
        if run_root apt-get install -y "$package"; then
          return
        fi
      done < <(venv_package_candidates "$version")
      ;;
    dnf|yum)
      run_root "$manager" install -y "python${version}" "python${version}-pip" && return
      run_root "$manager" install -y python3 python3-pip && return
      ;;
    apk)
      run_root apk add --no-cache python3 py3-pip py3-virtualenv && return
      ;;
  esac
  die "Could not install Python virtual environment support."
}

ensure_service_account() {
  if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    return
  fi
  run_root useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
}

install_application_files() {
  local python_minor
  python_minor="$(detect_python_minor)" || die "Python 3 is required."
  install_venv_package "$python_minor"
  ensure_service_account

  run_root mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$(dirname "$LOCK_PATH")"
  run_root install -m 0755 "$PROJECT_DIR/$SCRIPT_NAME" "$RUNTIME_PATH"
  run_root install -m 0644 "$PROJECT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

  if [ "$DRY_RUN" -eq 0 ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install --upgrade pip
    "$VENV_DIR/bin/python" -m pip install -r "$INSTALL_DIR/requirements.txt"
    run_root chown -R root:root "$INSTALL_DIR"
    run_root chmod -R go-w "$INSTALL_DIR"
    run_root chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
    run_root chown -R root:"$SERVICE_USER" "$CONFIG_DIR"
  else
    info "[dry-run] would create $VENV_DIR and install requirements"
  fi
}

secure_config_ownership() {
  local path
  [ "$DRY_RUN" -eq 0 ] || return 0
  for path in "$CONFIG_PATH" "$LDAP_SECRET_PATH" "$SMTP_SECRET_PATH"; do
    [ -f "$path" ] || continue
    chmod 640 "$path"
    run_root chown "root:$SERVICE_USER" "$path"
  done
  if [ -f "$LDAP_CA_PATH" ]; then
    chmod 640 "$LDAP_CA_PATH"
    run_root chown "root:$SERVICE_USER" "$LDAP_CA_PATH"
  fi
  run_root chmod 750 "$CONFIG_DIR"
  run_root chown "root:$SERVICE_USER" "$CONFIG_DIR"
}

resolve_dc() {
  local fqdn="$1"
  if getent ahosts "$fqdn" >/dev/null 2>&1; then
    return 0
  fi
  command -v host >/dev/null 2>&1 && host "$fqdn" >/dev/null 2>&1
}

ensure_hosts_mapping() {
  local ip="$1"
  local fqdn="$2"
  local hosts_path
  hosts_path="$(root_path /etc/hosts)"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would add $ip $fqdn to $hosts_path"
    return
  fi
  mkdir -p "$(dirname "$hosts_path")"
  touch "$hosts_path"
  if ! awk -v ip="$ip" -v host="$fqdn" '
    $1 == ip {
      for (i=2; i<=NF; i++) if ($i == host) found=1
    }
    END { exit found ? 0 : 1 }
  ' "$hosts_path"; then
    printf '%s %s # ad-password-sentinel\n' "$ip" "$fqdn" >> "$hosts_path"
  fi
}

tcp_reachable() {
  local host="$1"
  local port="$2"
  valid_fqdn "$host" || valid_ipv4 "$host" || {
    warn "Refusing invalid network target: $host"
    return 1
  }
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "$host" "$port"
  else
    python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=5):
    pass
PY
  fi
}

tls_certificate_valid() {
  local connect_host="$1"
  local tls_name="$2"
  local port="$3"
  openssl s_client -connect "${connect_host}:${port}" -servername "$tls_name" \
    -verify_return_error </dev/null 2>/dev/null |
    openssl x509 -noout -checkend 0 >/dev/null 2>&1
}

install_operator_ca_file() {
  local source_path="$1"
  local expected_fingerprint="$2"
  local actual_fingerprint

  [ -f "$source_path" ] || {
    warn "CA certificate not found: $source_path"
    return 1
  }
  actual_fingerprint="$(
    openssl x509 -in "$source_path" -noout -fingerprint -sha256 2>/dev/null |
      awk -F= 'NF > 1 { gsub(":", "", $2); print toupper($2) }'
  )"
  [ -n "$actual_fingerprint" ] || {
    warn "Could not read a SHA-256 fingerprint from $source_path"
    return 1
  }
  expected_fingerprint="$(printf '%s' "$expected_fingerprint" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]')"
  [ "$actual_fingerprint" = "$expected_fingerprint" ] || {
    warn "Fingerprint mismatch for $source_path"
    warn "Expected: $expected_fingerprint"
    warn "Actual  : $actual_fingerprint"
    return 1
  }
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would install application CA file $source_path to $LDAP_CA_PATH"
    return 0
  fi
  run_root install -m 0640 "$source_path" "$LDAP_CA_PATH"
  run_root chown "root:$SERVICE_USER" "$LDAP_CA_PATH"
}

runtime_check() {
  local check="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would run runtime verification: $check $*"
    return 0
  fi
  if [ "$(id -u)" -eq 0 ] && [ "$INSTALLER_TEST_MODE" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$SERVICE_USER" -- "$VENV_DIR/bin/python" "$RUNTIME_PATH" "$check" --config "$CONFIG_PATH" "$@"
  else
    "$VENV_DIR/bin/python" "$RUNTIME_PATH" "$check" --config "$CONFIG_PATH" "$@"
  fi
}

collect_directory_config() {
  local dc_fqdn=""
  local dc_ip=""
  local domain
  local base_dn
  local bind_short=""
  local bind_user
  local bind_password=""
  local directory_label
  local warning_days
  local notify_days
  local notify_users="false"
  local allowed_domains
  local mail_from
  local report_to
  local connect_host

  while ! valid_fqdn "$dc_fqdn"; do
    dc_fqdn="$(ui_input "Domain controller FQDN (example: dc.domain.local)")" || die "Cancelled."
    valid_fqdn "$dc_fqdn" || warn "Enter a fully qualified host name such as dc.domain.local."
  done
  dc_ip="$(ui_input "Optional DC IP fallback (blank to use DNS only)")" || die "Cancelled."
  [ -z "$dc_ip" ] || valid_ipv4 "$dc_ip" || die "Invalid IPv4 fallback: $dc_ip"

  domain="$(domain_from_fqdn "$dc_fqdn")"
  base_dn="$(base_dn_from_domain "$domain")"
  while [ -z "$bind_short" ] || [[ "$bind_short" == *"@"* ]]; do
    bind_short="$(ui_input "Short bind username (example: svc_notify)")" || die "Cancelled."
  done
  bind_user="$(bind_upn "$bind_short" "$domain")"
  ui_yes_no "Use bind identity $bind_user?" yes || die "Bind identity was not confirmed."
  bind_password="$(ui_input "Bind password" "" 1)" || die "Cancelled."
  [ -n "$bind_password" ] || die "Bind password cannot be empty."

  directory_label="$(ui_input "Directory label" "$domain")"
  warning_days="$(ui_input "Warning window in days" "14")"
  notify_days="$(ui_input "Notification days" "14,7,3,1,0")"
  ui_yes_no "Notify end users after verification?" no && notify_users="true"
  allowed_domains="$(ui_input "Allowed user email domains" "$domain")"
  mail_from="$(ui_input "Sender email" "noreply@$domain")"
  report_to="$(ui_input "Technical report recipient" "it@$domain")"

  connect_host="$dc_fqdn"
  if ! resolve_dc "$dc_fqdn"; then
    if [ -n "$dc_ip" ]; then
      connect_host="$dc_ip"
      warn "DNS did not resolve $dc_fqdn; network and TLS checks will use $dc_ip with SNI $dc_fqdn."
      ensure_hosts_mapping "$dc_ip" "$dc_fqdn"
    else
      die "DNS could not resolve $dc_fqdn and no IP fallback was supplied."
    fi
  fi
  tcp_reachable "$connect_host" 636 ||
    warn "TCP 636 is not reachable. The authenticated LDAPS check will decide whether setup can continue."
  tls_certificate_valid "$connect_host" "$dc_fqdn" 636 ||
    warn "The LDAPS certificate is unavailable, expired, hostname-mismatched, or not trusted."

  write_secure_file "$LDAP_SECRET_PATH" "$bind_password"
  CONFIG_CONTENT=$(cat <<EOF
LDAP_MODE=ldaps
LDAP_HOST=$dc_fqdn
LDAP_PORT=636
LDAP_BASE_DN=$base_dn
LDAP_BIND_USER=$bind_user
LDAP_PASSWORD_FILE=$LDAP_SECRET_PATH
LDAP_TLS_VALIDATE=true
AD_SERVER=ldaps://$dc_fqdn:636
AD_BASE_DN=$base_dn
AD_BIND_USER=$bind_user
ALLOW_INSECURE_LDAP=false
DIRECTORY_LABEL=$directory_label
WARNING_DAYS=$warning_days
NOTIFY_DAYS=$notify_days
NOTIFY_USERS=$notify_users
USER_MAIL_ALLOWED_DOMAINS=$allowed_domains
MAIL_FROM=$mail_from
TECH_REPORT_TO=$report_to
USER_MAIL_SUBJECT=Your password will expire soon
MAIL_TRANSPORT=sendmail
SENDMAIL_PATH=/usr/sbin/sendmail
TEST_MODE=true
ALWAYS_SEND_REPORT=true
REPORT_DIR=$LOG_DIR
REPORT_CSV=ad-password-expiry-report.csv
EOF
)
  write_config_file "$CONFIG_CONTENT"
  LDAP_CONNECT_HOST="$connect_host"
  LDAP_TLS_NAME="$dc_fqdn"
}

configure_mail() {
  local choice
  local smtp_host
  local smtp_port
  local smtp_user
  local smtp_password
  local smtp_security
  choice="$(ui_menu "Mail transport" 1 \
    1 "Use existing sendmail/Postfix" \
    2 "Use an SMTP relay" \
    3 "Skip mail setup and keep TEST_MODE enabled")" || die "Cancelled."

  case "$choice" in
    1)
      set_config_value MAIL_TRANSPORT sendmail
      set_config_value SENDMAIL_PATH /usr/sbin/sendmail
      ;;
    2)
      smtp_host="$(ui_input "SMTP relay host")"
      smtp_port="$(ui_input "SMTP relay port" "587")"
      smtp_security="$(ui_menu "SMTP security" 1 1 "STARTTLS" 2 "Implicit TLS" 3 "None")"
      case "$smtp_security" in
        1) smtp_security="starttls" ;;
        2) smtp_security="ssl" ;;
        3) smtp_security="none" ;;
        *) die "Invalid SMTP security choice." ;;
      esac
      smtp_user="$(ui_input "SMTP username (blank for none)")"
      set_config_value MAIL_TRANSPORT smtp
      set_config_value SMTP_HOST "$smtp_host"
      set_config_value SMTP_PORT "$smtp_port"
      set_config_value SMTP_SECURITY "$smtp_security"
      if [ -n "$smtp_user" ]; then
        [ "$smtp_security" != "none" ] ||
          die "SMTP authentication requires STARTTLS or implicit TLS."
        smtp_password="$(ui_input "SMTP password" "" 1)"
        write_secure_file "$SMTP_SECRET_PATH" "$smtp_password"
        set_config_value SMTP_USER "$smtp_user"
        set_config_value SMTP_PASSWORD_FILE "$SMTP_SECRET_PATH"
      fi
      ;;
    3)
      set_config_value MAIL_TRANSPORT sendmail
      set_config_value SENDMAIL_PATH /usr/sbin/sendmail
      return 2
      ;;
    *) die "Invalid mail transport choice." ;;
  esac
}

explain_ldaps_failure() {
  warn "Authenticated LDAPS failed."
  warn "Check firewall routing to the domain controller on TCP 636, DNS/DC reachability,"
  warn "the bind credentials, and whether the DC certificate chain is trusted by this host."
  warn "Do not trust a certificate captured from the network. Use the issuing CA file"
  warn "from a trusted source and verify its SHA-256 fingerprint out of band."
}

verify_directory() {
  local connect_host="${LDAP_CONNECT_HOST:-$(config_value LDAP_HOST)}"
  local tls_name="${LDAP_TLS_NAME:-$(config_value LDAP_HOST)}"

  if runtime_check check-ldap; then
    return 0
  fi

  explain_ldaps_failure
  if ui_yes_no "Provide a trusted CA certificate file for LDAPS and retry?" yes; then
    local ca_source=""
    local ca_fingerprint=""
    ca_source="$(ui_input "CA certificate path (PEM/CRT)")" || die "Cancelled."
    ca_fingerprint="$(ui_input "Expected SHA-256 fingerprint")" || die "Cancelled."
    if install_operator_ca_file "$ca_source" "$ca_fingerprint"; then
      set_config_value LDAP_CA_FILE "$LDAP_CA_PATH"
      set_config_value LDAP_TLS_VALIDATE true
      if runtime_check check-ldap; then
        return 0
      fi
    fi
    explain_ldaps_failure
  fi

  if ! ui_yes_no "Explicitly fall back to unencrypted LDAP on TCP 389?" no; then
    return 1
  fi
  tcp_reachable "$connect_host" 389 || warn "TCP 389 is not reachable."
  set_config_value LDAP_MODE ldap
  set_config_value LDAP_PORT 389
  set_config_value LDAP_TLS_VALIDATE false
  set_config_value AD_SERVER "ldap://$tls_name:389"
  set_config_value ALLOW_INSECURE_LDAP true
  if runtime_check check-ldap; then
    return 0
  fi
  warn "LDAP fallback failed. Setup will stop without enabling the application."
  return 1
}

verify_mail() {
  local recipient
  recipient="$(ui_input "Test mail recipient" "$(config_value TECH_REPORT_TO)")"
  if ! ui_yes_no "Send a test message to $recipient?" yes; then
    warn "Mail verification was declined; TEST_MODE will remain enabled."
    return 1
  fi
  runtime_check check-mail --to "$recipient"
}

install_cron() {
  local choice
  local expression
  choice="$(ui_menu "Schedule" 1 \
    1 "Daily at 08:00" \
    2 "Weekly Monday at 08:00" \
    3 "Monday, Wednesday, Friday at 08:00")" || die "Cancelled."
  expression="$(cron_expression "$choice")" || die "Invalid schedule."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would write $CRON_PATH"
    return
  fi
  mkdir -p "$(dirname "$CRON_PATH")"
  printf '%s %s /usr/bin/flock -n %s %s/bin/python %s run --config %s\n' \
    "$expression" "$SERVICE_USER" "$LOCK_PATH" "$VENV_DIR" "$RUNTIME_PATH" "$CONFIG_PATH" > "$CRON_PATH"
  chmod 644 "$CRON_PATH"
}

preserve_or_collect_config() {
  if [ -f "$CONFIG_PATH" ] &&
    ui_yes_no "Existing configuration found. Preserve it and verify the current settings?" yes; then
    info "Preserving existing configuration: $CONFIG_PATH"
    chmod 640 "$CONFIG_PATH"
    return
  fi
  collect_directory_config
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --test-mode) INSTALLER_TEST_MODE=1 ;;
      --ui)
        shift
        [ "$#" -gt 0 ] || die "--ui requires a value"
        UI_MODE="$1"
        ;;
      --ui=*) UI_MODE="${1#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  case "$UI_MODE" in
    auto|whiptail|plain) ;;
    *) die "Unsupported UI mode: $UI_MODE" ;;
  esac
}

main() {
  local mail_ready=1
  parse_args "$@"
  [ "$(uname -s)" = "Linux" ] || die "This installer supports Linux only."
  if [ "$DRY_RUN" -eq 0 ] && [ "$INSTALLER_TEST_MODE" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "Run this installer with sudo or as root."
  fi
  if [ "$UI_MODE" = "whiptail" ] && ! whiptail_usable; then
    warn "Whiptail is unavailable or unusable; falling back to plain prompts."
    UI_MODE=plain
  elif [ "$UI_MODE" = "auto" ] && whiptail_usable; then
    UI_MODE=whiptail
  else
    UI_MODE=plain
  fi

  info "$APP_NAME Linux installer"
  [ "$DRY_RUN" -eq 0 ] || info "Dry-run mode: no system files will be changed."
  install_application_files
  preserve_or_collect_config
  secure_config_ownership

  if ! verify_directory; then
    set_config_value TEST_MODE true
    die "Directory verification failed or insecure LDAP fallback was declined. The app and schedule were not enabled."
  fi
  runtime_check validate
  configure_mail || mail_ready=0
  secure_config_ownership
  if [ "$mail_ready" -eq 1 ]; then
    verify_mail || mail_ready=0
  fi
  if [ "$mail_ready" -ne 1 ]; then
    set_config_value TEST_MODE true
    die "Mail verification did not pass. The app and schedule were not enabled."
  fi

  set_config_value TEST_MODE false
  install_cron
  info "Installation and verification completed."
  info "Configuration: $CONFIG_PATH"
  info "Schedule: $CRON_PATH"
}

if [ "${ADPS_TEST_SOURCE:-0}" != "1" ]; then
  main "$@"
fi
