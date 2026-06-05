FROM python:3.12-slim

WORKDIR /opt/ad-password-sentinel

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates cron util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN python -m venv .venv \
    && .venv/bin/pip install --upgrade pip \
    && .venv/bin/pip install -r requirements.txt

COPY notify_ad_password_expiry.py .
COPY docker/crontab /etc/cron.d/ad-password-sentinel
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod 0644 /etc/cron.d/ad-password-sentinel \
    && chmod 0755 /entrypoint.sh \
    && mkdir -p /etc/ad-password-sentinel /var/log/ad-password-sentinel /var/lock

ENTRYPOINT ["/entrypoint.sh"]
