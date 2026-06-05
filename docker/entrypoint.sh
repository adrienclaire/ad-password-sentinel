#!/bin/sh
set -eu

if [ ! -f /etc/ad-password-sentinel/config.env ]; then
    echo "Missing /etc/ad-password-sentinel/config.env. Mount your config file before starting the container." >&2
    exit 1
fi

cron -f
