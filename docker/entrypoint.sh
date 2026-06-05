#!/bin/sh
set -eu

if [ ! -f /etc/ad-password-sentinel/config.env ]; then
    echo "Missing /etc/ad-password-sentinel/config.env. Mount your config file before starting the container." >&2
    exit 1
fi

if [ -f /usr/local/share/ca-certificates/ad-password-sentinel-dc.crt ]; then
    update-ca-certificates
fi

cron -f
