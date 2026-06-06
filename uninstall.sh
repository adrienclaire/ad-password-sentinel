#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AD Password Sentinel"
SERVICE_USER="ad-password-sentinel"
UI_MODE="${ADPS_UI:-auto}"
DRY_RUN=0
ADPS_ROOT="${ADPS_ROOT:-}"

root_path() {
  printf '%s%s' "$ADPS_ROOT" "$1"
}

INSTALL_DIR="$(root_path /opt/ad-password-sentinel)"
CONFIG_DIR="$(root_path /etc/ad-password-sentinel)"
LOG_DIR="$(root_path /var/log/ad-password-sentinel)"
CRON_PATH="$(root_path /etc/cron.d/ad-password-sentinel)"

usage() {
  cat <<'EOF'
Usage: sudo bash uninstall.sh [--dry-run] [--ui auto|whiptail|plain]

  --dry-run    Show removal actions without deleting files.
  --ui         Use whiptail when usable (default), or force plain prompts.
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
    sudo "$@"
  fi
}

tty_usable() {
  [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

ui_can_prompt() {
  tty_usable && [ "${TERM:-dumb}" != "dumb" ]
}

whiptail_usable() {
  [ "$UI_MODE" != "plain" ] &&
    command -v whiptail >/dev/null 2>&1 &&
    ui_can_prompt
}

plain_input() {
  local prompt="$1"
  local default="${2:-}"
  local answer=""
  local suffix=""

  [ -n "$default" ] && suffix=" [$default]"
  if tty_usable; then
    printf '%s%s: ' "$prompt" "$suffix" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
  else
    printf '%s%s: ' "$prompt" "$suffix" >&2
    IFS= read -r answer || answer=""
  fi
  printf '%s' "${answer:-$default}"
}

ui_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
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

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
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

remove_path_if_present() {
  local path="$1"
  [ -e "$path" ] || return 0
  run_root rm -rf -- "$path"
}

main() {
  local remove_runtime=1
  local remove_data=0

  parse_args "$@"
  [ "$(uname -s)" = "Linux" ] || die "This uninstaller supports Linux only."
  if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "Run this uninstaller with sudo or as root."
  fi
  if [ "$UI_MODE" = "whiptail" ] && ! whiptail_usable; then
    warn "Whiptail is unavailable or unusable; falling back to plain prompts."
    UI_MODE=plain
  elif [ "$UI_MODE" = "auto" ] && whiptail_usable; then
    UI_MODE=whiptail
  else
    UI_MODE=plain
  fi

  info "$APP_NAME Linux uninstaller"
  [ "$DRY_RUN" -eq 0 ] || info "Dry-run mode: no system files will be changed."

  ui_yes_no "Are you sure you want to uninstall $APP_NAME from this server?" no ||
    die "Uninstall cancelled."

  ui_yes_no "Also delete configuration, secrets, CA files, and reports under /etc and /var?" no &&
    remove_data=1

  remove_path_if_present "$CRON_PATH"
  remove_path_if_present "$INSTALL_DIR"

  if [ "$remove_data" -eq 1 ]; then
    remove_path_if_present "$CONFIG_DIR"
    remove_path_if_present "$LOG_DIR"
  fi

  if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    run_root userdel "$SERVICE_USER" || warn "Could not remove user $SERVICE_USER."
  fi

  info "Uninstall completed."
  if [ "$remove_data" -eq 1 ]; then
    info "Removed runtime, schedule, configuration, secrets, CA files, and reports."
  else
    info "Removed runtime and schedule. Configuration, secrets, and reports were kept."
  fi
}

main "$@"
