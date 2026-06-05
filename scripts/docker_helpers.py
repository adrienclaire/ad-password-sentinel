INSTALL_DIR = "/opt/ad-password-sentinel"
CONFIG_PATH = "/etc/ad-password-sentinel/config.env"
LOCK_PATH = "/var/lock/ad-password-sentinel.lock"


def build_container_cron_command():
    return (
        f"/usr/bin/flock -n {LOCK_PATH} "
        f"{INSTALL_DIR}/.venv/bin/python {INSTALL_DIR}/notify_ad_password_expiry.py "
        f"--config {CONFIG_PATH}"
    )
