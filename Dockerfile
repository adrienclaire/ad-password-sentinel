FROM python:3.12-slim

WORKDIR /opt/ad-password-sentinel

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 sentinel \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent sentinel

COPY requirements.txt .
RUN python -m venv .venv \
    && .venv/bin/pip install --upgrade pip \
    && .venv/bin/pip install -r requirements.txt

COPY notify_ad_password_expiry.py .
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh \
    && mkdir -p /etc/ad-password-sentinel /var/log/ad-password-sentinel \
    && chown -R 10001:10001 /var/log/ad-password-sentinel

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 10001:10001

ENTRYPOINT ["/entrypoint.sh"]
