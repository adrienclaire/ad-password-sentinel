#!/bin/sh
set -eu

CONFIG_SOURCE=/etc/ad-password-sentinel/config.env
RUNTIME_DIR=/tmp/ad-password-sentinel
RUNTIME_CONFIG="$RUNTIME_DIR/config.env"
PYTHON=/opt/ad-password-sentinel/.venv/bin/python
APPLICATION=/opt/ad-password-sentinel/notify_ad_password_expiry.py

if [ ! -f "$CONFIG_SOURCE" ]; then
    echo "Missing $CONFIG_SOURCE. Run docker/setup.sh or docker/setup.ps1 first." >&2
    exit 1
fi

umask 077
mkdir -p "$RUNTIME_DIR"
cp "$CONFIG_SOURCE" "$RUNTIME_CONFIG"
chmod 0600 "$RUNTIME_CONFIG"

command=${1:-run}
if [ "$#" -gt 0 ]; then
    shift
fi

case "$command" in
    run)
        exec "$PYTHON" "$APPLICATION" run --config "$RUNTIME_CONFIG" "$@"
        ;;
    check-config|validate)
        exec "$PYTHON" "$APPLICATION" validate --config "$RUNTIME_CONFIG" "$@"
        ;;
    check-ldap)
        exec "$PYTHON" "$APPLICATION" check-ldap --config "$RUNTIME_CONFIG" "$@"
        ;;
    check-mail)
        if [ "${1:-}" = "--to" ]; then
            shift
        fi
        if [ "$#" -ne 1 ]; then
            echo "Usage: check-mail [--to] EMAIL" >&2
            exit 2
        fi
        exec "$PYTHON" "$APPLICATION" check-mail --config "$RUNTIME_CONFIG" --to "$1"
        ;;
    *)
        exec "$PYTHON" "$APPLICATION" "$command" --config "$RUNTIME_CONFIG" "$@"
        ;;
esac
