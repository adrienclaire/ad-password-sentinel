#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ADPS_TEST_SOURCE=1
# shellcheck source=../install.sh
source "$repo_root/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$expected" = "$actual" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: missing '$needle'" ;;
  esac
}

assert_eq "domain.local" "$(domain_from_fqdn dc.domain.local)" "domain derivation"
assert_eq "DC=domain,DC=local" "$(base_dn_from_domain domain.local)" "base DN derivation"
assert_eq "svc_notify@domain.local" "$(bind_upn svc_notify domain.local)" "bind UPN derivation"
assert_eq "0 8 * * *" "$(cron_expression daily)" "daily cron"
assert_eq "0 8 * * 1" "$(cron_expression weekly)" "weekly cron"
assert_eq "0 8 * * 1,3,5" "$(cron_expression weekdays)" "three-times-weekly cron"

pkg_output="$(venv_package_candidates 3.12)"
assert_eq $'python3.12-venv\npython3-venv' "$pkg_output" "venv package order"

ui_body="$(awk '
  /^ui_can_prompt\(\) \{/ { found=1 }
  found { print }
  found && /^\}/ { exit }
' "$repo_root/install.sh")"
prompt_body="$(awk '
  /^plain_input\(\) \{/ { found=1 }
  found { print }
  found && /^\}/ { exit }
' "$repo_root/install.sh")"
interactive_body="$(awk '
  /^run_interactive\(\) \{/ { found=1 }
  found { print }
  found && /^\}/ { exit }
' "$repo_root/install.sh")"

assert_contains "$ui_body" "/dev/tty" "UI availability check"
assert_contains "$prompt_body" "/dev/tty" "plain prompt input"
assert_contains "$interactive_body" "< /dev/tty" "interactive stdin"
assert_contains "$interactive_body" "> /dev/tty" "interactive stdout"

if grep -Eq '\[ -t [01] \]' <<<"$ui_body"; then
  fail "ui_can_prompt must rely on /dev/tty, not inherited stdin/stdout"
fi

printf 'installer UI and helper checks passed\n'
