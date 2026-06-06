#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

prompt_required() {
    local variable_name="$1"
    local prompt="$2"
    local value=""
    while [[ -z "$value" ]]; do
        read -r -p "$prompt: " value
    done
    printf -v "$variable_name" '%s' "$value"
}

prompt_default() {
    local variable_name="$1"
    local prompt="$2"
    local default_value="$3"
    local value=""
    read -r -p "$prompt [$default_value]: " value
    printf -v "$variable_name" '%s' "${value:-$default_value}"
}

prompt_required DC_FQDN "Domain controller FQDN"
prompt_required DC_IP "Domain controller IP fallback"

IFS='.' read -r -a dc_labels <<< "${DC_FQDN%.}"
if (( ${#dc_labels[@]} < 2 )); then
    echo "DC FQDN must include a host and domain, for example dc01.example.com." >&2
    exit 1
fi

domain_labels=("${dc_labels[@]:1}")
DOMAIN="$(IFS='.'; echo "${domain_labels[*]}")"
BASE_DN=""
for label in "${domain_labels[@]}"; do
    [[ -n "$BASE_DN" ]] && BASE_DN+=","
    BASE_DN+="DC=$label"
done

prompt_default BIND_ACCOUNT "LDAP bind account name or UPN" "svc_ad_password_sentinel"
if [[ "$BIND_ACCOUNT" == *"@"* ]]; then
    BIND_UPN="$BIND_ACCOUNT"
else
    BIND_UPN="$BIND_ACCOUNT@$DOMAIN"
fi

read -r -s -p "LDAP bind password: " LDAP_PASSWORD
echo
[[ -n "$LDAP_PASSWORD" ]] || { echo "LDAP password must not be empty." >&2; exit 1; }

prompt_required SMTP_HOST "Direct SMTP relay host"
prompt_default SMTP_PORT "SMTP relay port" "587"
prompt_default SMTP_SECURITY "SMTP security (starttls, ssl, none)" "starttls"
read -r -p "SMTP username (leave blank for relay without authentication): " SMTP_USERNAME
SMTP_PASSWORD=""
if [[ -n "$SMTP_USERNAME" ]]; then
    if [[ "$SMTP_SECURITY" == "none" ]]; then
        echo "SMTP authentication requires starttls or ssl." >&2
        exit 1
    fi
    read -r -s -p "SMTP password: " SMTP_PASSWORD
    echo
fi
prompt_required MAIL_FROM "Sender email address"
prompt_required TECH_REPORT_TO "Technical report recipient"
prompt_default TZ_VALUE "Container timezone" "Europe/Paris"
read -r -p "CA certificate path for LDAPS (leave blank when publicly trusted): " CA_SOURCE

mkdir -p config secrets certs reports
chmod 700 config secrets certs
chmod 770 reports

CONTAINER_UID="$(id -u)"
CONTAINER_GID="$(id -g)"
if [[ "$CONTAINER_UID" == "0" ]]; then
    CONTAINER_UID=10001
    CONTAINER_GID=10001
    chown "$CONTAINER_UID:$CONTAINER_GID" reports
fi
printf '%s\n' "$LDAP_PASSWORD" > secrets/ldap-password
printf '%s\n' "$SMTP_PASSWORD" > secrets/smtp-password
chmod 600 secrets/ldap-password secrets/smtp-password

if [[ -n "$CA_SOURCE" ]]; then
    [[ -f "$CA_SOURCE" ]] || { echo "CA certificate not found: $CA_SOURCE" >&2; exit 1; }
    cp "$CA_SOURCE" certs/ca.crt
    CA_CONFIG_LINE="LDAP_CA_FILE=/run/certs/ad-password-sentinel-ca.crt"
else
    : > certs/ca.crt
    CA_CONFIG_LINE=""
fi
chmod 600 certs/ca.crt

cat > config/config.env <<EOF
TEST_MODE=true
LDAP_MODE=ldaps
LDAP_HOST=$DC_FQDN
LDAP_PORT=636
LDAP_BASE_DN=$BASE_DN
LDAP_BIND_USER=$BIND_UPN
LDAP_PASSWORD_FILE=/run/secrets/ldap-password
LDAP_TLS_VALIDATE=true
$CA_CONFIG_LINE
DIRECTORY_LABEL=$DOMAIN Active Directory
WARNING_DAYS=14
NOTIFY_DAYS=14,7,3,1,0
NOTIFY_USERS=false
USER_MAIL_ALLOWED_DOMAINS=$DOMAIN
MAIL_TRANSPORT=smtp
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_SECURITY=$SMTP_SECURITY
SMTP_USER=$SMTP_USERNAME
SMTP_PASSWORD_FILE=/run/secrets/smtp-password
MAIL_FROM=$MAIL_FROM
TECH_REPORT_TO=$TECH_REPORT_TO
USER_MAIL_SUBJECT=Your password will expire soon
ALWAYS_SEND_REPORT=true
REPORT_DIR=/var/log/ad-password-sentinel
REPORT_CSV=ad-password-expiry-report.csv
EOF
chmod 600 config/config.env

cat > .env <<EOF
TZ=$TZ_VALUE
LDAP_HOST=$DC_FQDN
LDAP_IP=$DC_IP
CONTAINER_UID=$CONTAINER_UID
CONTAINER_GID=$CONTAINER_GID
HOST_CONFIG_FILE=./config/config.env
HOST_LDAP_SECRET_FILE=./secrets/ldap-password
HOST_SMTP_SECRET_FILE=./secrets/smtp-password
HOST_CA_FILE=./certs/ca.crt
HOST_REPORTS_DIR=./reports
EOF
chmod 600 .env

CONFIG_ABS="$(cd config && pwd)/config.env"
LDAP_SECRET_ABS="$(cd secrets && pwd)/ldap-password"
SMTP_SECRET_ABS="$(cd secrets && pwd)/smtp-password"
CA_CERT_ABS="$(cd certs && pwd)/ca.crt"
REPORTS_ABS="$(cd reports && pwd)"

echo
echo "Secure Docker configuration created with TEST_MODE=true."
echo "DNS fallback: Compose maps $DC_FQDN to $DC_IP inside the container."
if [[ -n "$CA_SOURCE" ]]; then
    echo "CA certificate: mounted read-only at /run/certs/ad-password-sentinel-ca.crt."
else
    echo "CA certificate: no custom certificate selected; certs/ca.crt is an empty placeholder."
fi
echo "Configuration, LDAP/SMTP secrets, and CA mounts are read-only; reports/ is writable."
echo

docker compose build
docker compose run --rm ad-password-sentinel validate
docker compose run --rm ad-password-sentinel check-ldap

echo
echo "Validation completed. TEST_MODE remains true."
read -r -p "Show the recommended host cron entry for 08:00 daily? [y/N]: " SHOW_SCHEDULE
if [[ "$SHOW_SCHEDULE" =~ ^[Yy]$ ]]; then
    cat <<EOF
0 8 * * * /usr/bin/docker run --rm --read-only \\
  --user ${CONTAINER_UID}:${CONTAINER_GID} \\
  --cap-drop ALL --security-opt no-new-privileges:true \\
  --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=700,uid=${CONTAINER_UID},gid=${CONTAINER_GID} \\
  --add-host ${DC_FQDN}:${DC_IP} \\
  -e TZ=${TZ_VALUE} \\
  -v ${CONFIG_ABS}:/etc/ad-password-sentinel/config.env:ro \\
  -v ${LDAP_SECRET_ABS}:/run/secrets/ldap-password:ro \\
  -v ${SMTP_SECRET_ABS}:/run/secrets/smtp-password:ro \\
  -v ${CA_CERT_ABS}:/run/certs/ad-password-sentinel-ca.crt:ro \\
  -v ${REPORTS_ABS}:/var/log/ad-password-sentinel:rw \\
  ad-password-sentinel:local run
EOF
fi
