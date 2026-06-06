#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local answer=""
    while true; do
        if [[ "$default" == "yes" ]]; then
            read -r -p "$prompt [Y/n]: " answer
        else
            read -r -p "$prompt [y/N]: " answer
        fi
        answer="${answer,,}"
        case "$answer" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            "") [[ "$default" == "yes" ]]; return ;;
            *) echo "Please answer yes or no." >&2 ;;
        esac
    done
}

echo "AD Password Sentinel Docker uninstall"

prompt_yes_no "Are you sure you want to remove the Docker deployment assets?" no || {
    echo "Uninstall cancelled." >&2
    exit 1
}

docker compose down || true

if prompt_yes_no "Delete generated Docker config, secrets, certs, reports, and .env?" no; then
    rm -rf config secrets certs reports .env
fi

echo "Docker uninstall completed."
