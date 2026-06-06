#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d)"
fakebin="$work_dir/fakebin"
root_dir="$work_dir/root"
log_file="$work_dir/installer.log"
command_log="$work_dir/commands.log"
mkdir -p "$fakebin" "$root_dir"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ ! -f "$log_file" ] || cat "$log_file" >&2
  exit 1
}

make_fake() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$fakebin/$name"
  chmod +x "$fakebin/$name"
}

make_fake id \
  '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "-u" ]; then printf "0\n"; else /usr/bin/id "$@"; fi'

make_fake python3 \
  '#!/usr/bin/env bash' \
  'printf "python3 %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
  'case "$*" in' \
  '  *"sys.version_info"*) printf "3.12\n" ;;' \
  '  *"-m venv"*) mkdir -p "$3/bin"; cp "$0" "$3/bin/python" ;;' \
  '  *" validate --config "*) exit 0 ;;' \
  '  *" check-ldap --config "*) exit 0 ;;' \
  '  *" check-mail "*--to*) exit 0 ;;' \
  'esac'

make_fake apt-get \
  '#!/usr/bin/env bash' \
  'printf "apt-get %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
  'exit 0'

make_fake getent \
  '#!/usr/bin/env bash' \
  'printf "10.20.30.40 STREAM dc.domain.local\n"'

make_fake nc \
  '#!/usr/bin/env bash' \
  'printf "nc %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
  'exit 0'

make_fake openssl \
  '#!/usr/bin/env bash' \
  'printf "openssl %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
  'case "$*" in *s_client*) printf "%s\n" "-----BEGIN CERTIFICATE-----" "ZmFrZQ==" "-----END CERTIFICATE-----" ;; esac' \
  'exit 0'

for name in chmod chown cp install mkdir systemctl update-ca-certificates useradd flock; do
  make_fake "$name" \
    '#!/usr/bin/env bash' \
    'printf "'"$name"' %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
    'case "'"$name"'" in' \
    '  install) /usr/bin/install "$@" ;;' \
    '  mkdir) /usr/bin/mkdir "$@" ;;' \
    '  cp) /usr/bin/cp "$@" ;;' \
    '  chmod) /usr/bin/chmod "$@" ;;' \
    '  *) exit 0 ;;' \
    'esac'
done

answers="$work_dir/answers.txt"
cat > "$answers" <<'ANSWERS'
dc.domain.local

svc_notify
y
super-secret
Example Directory
14
14,7,3,1,0
n
example.com
noreply@example.com
it@example.com
1
it@example.com
y
1
ANSWERS

if ! command -v script >/dev/null 2>&1; then
  printf 'SKIP: script command is required for pseudo-TTY integration testing\n'
  exit 77
fi

command_to_run=$(
  printf 'cd %q && env PATH=%q ADPS_ROOT=%q ADPS_COMMAND_LOG=%q ADPS_UI=plain TERM=xterm bash %q --test-mode' \
    "$repo_root" \
    "$fakebin:$PATH" \
    "$root_dir" \
    "$command_log" \
    "$repo_root/install.sh"
)

script -q -e -c "$command_to_run" "$log_file" < "$answers"

config="$root_dir/etc/ad-password-sentinel/config.env"
secret="$root_dir/etc/ad-password-sentinel/ldap-password"
cron="$root_dir/etc/cron.d/ad-password-sentinel"

[ -f "$config" ] || fail "config was not written"
[ -f "$secret" ] || fail "LDAP secret was not written"
[ -f "$cron" ] || fail "cron was not installed after verification"
grep -Fxq 'LDAP_HOST=dc.domain.local' "$config" || fail "LDAPS host missing"
grep -Fxq 'LDAP_BASE_DN=DC=domain,DC=local' "$config" || fail "base DN missing"
grep -Fxq 'LDAP_BIND_USER=svc_notify@domain.local' "$config" || fail "bind UPN missing"
grep -Fxq 'LDAP_MODE=ldaps' "$config" || fail "LDAPS mode missing"
grep -Fxq 'TEST_MODE=false' "$config" || fail "TEST_MODE was not disabled after verification"
grep -Fq 'ad-password-sentinel' "$cron" || fail "service account missing from cron"
grep -Fq '/usr/bin/flock -n' "$cron" || fail "flock missing from cron"
grep -Fq ' run --config ' "$cron" || fail "explicit run subcommand missing from cron"
[ "$(stat -c '%a' "$secret")" = "640" ] || fail "LDAP secret is not mode 0640"
grep -Fq 'install -y python3.12-venv' "$command_log" || fail "matching venv package was not attempted"
grep -Fq -- 'check-ldap --config' "$command_log" || fail "runtime LDAP verification was not called"

printf 'installer pseudo-TTY integration flow passed\n'

failure_root="$work_dir/failure-root"
failure_log="$work_dir/failure.log"
mkdir -p "$failure_root"
make_fake python3 \
  '#!/usr/bin/env bash' \
  'printf "python3 %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
  'case "$*" in' \
  '  *"sys.version_info"*) printf "3.12\n" ;;' \
  '  *"-m venv"*) mkdir -p "$3/bin"; cp "$0" "$3/bin/python" ;;' \
  '  *" check-ldap --config "*) exit 41 ;;' \
  'esac' \
  'exit 0'

failure_answers="$work_dir/failure-answers.txt"
cat > "$failure_answers" <<'ANSWERS'
dc.domain.local

svc_notify
y
super-secret
Example Directory
14
14,7,3,1,0
n
example.com
noreply@example.com
it@example.com
n
n
ANSWERS

failure_command=$(
  printf 'cd %q && env PATH=%q ADPS_ROOT=%q ADPS_COMMAND_LOG=%q ADPS_UI=plain TERM=xterm bash %q --test-mode' \
    "$repo_root" \
    "$fakebin:$PATH" \
    "$failure_root" \
    "$command_log" \
    "$repo_root/install.sh"
)

if script -q -e -c "$failure_command" "$failure_log" < "$failure_answers"; then
  fail "installer unexpectedly succeeded after LDAPS failure and declined fallback"
fi

failure_config="$failure_root/etc/ad-password-sentinel/config.env"
[ -f "$failure_config" ] || fail "failure-path config was not retained for repair"
grep -Fxq 'TEST_MODE=true' "$failure_config" || fail "failure path disabled TEST_MODE"
[ ! -e "$failure_root/etc/cron.d/ad-password-sentinel" ] || fail "failure path created cron"
grep -Fq 'firewall routing' "$failure_log" || fail "failure explanation omitted firewall guidance"
grep -Fq 'certificate chain' "$failure_log" || fail "failure explanation omitted certificate trust guidance"

printf 'installer LDAPS failure gate passed\n'

make_fake python3 \
  '#!/usr/bin/env bash' \
  'printf "python3 %s\n" "$*" >> "$ADPS_COMMAND_LOG"' \
  'case "$*" in' \
  '  *"sys.version_info"*) printf "3.12\n" ;;' \
  '  *"-m venv"*) mkdir -p "$3/bin"; cp "$0" "$3/bin/python" ;;' \
  '  *" validate --config "*|*" check-ldap --config "*|*" check-mail "*--to*) exit 0 ;;' \
  'esac'

printf 'CUSTOM_KEEP=yes\n' >> "$config"
reinstall_answers="$work_dir/reinstall-answers.txt"
cat > "$reinstall_answers" <<'ANSWERS'

1
it@example.com
y
1
ANSWERS

if ! script -q -e -c "$command_to_run" "$work_dir/reinstall.log" < "$reinstall_answers"; then
  fail "reinstall flow failed"
fi
grep -Fxq 'CUSTOM_KEEP=yes' "$config" || fail "reinstall discarded an existing config entry"
printf 'installer reinstall preservation flow passed\n'

dry_root="$work_dir/dry-root"
mkdir -p "$dry_root"
dry_answers="$work_dir/dry-answers.txt"
cat > "$dry_answers" <<'ANSWERS'
dc.domain.local

svc_notify
y
super-secret
Example Directory
14
14,7,3,1,0
n
example.com
noreply@example.com
it@example.com
1
it@example.com
y
1
ANSWERS

dry_command=$(
  printf 'cd %q && env PATH=%q ADPS_ROOT=%q ADPS_COMMAND_LOG=%q ADPS_UI=plain TERM=xterm bash %q --dry-run --test-mode' \
    "$repo_root" \
    "$fakebin:$PATH" \
    "$dry_root" \
    "$command_log" \
    "$repo_root/install.sh"
)

if ! script -q -e -c "$dry_command" "$work_dir/dry-run.log" < "$dry_answers"; then
  fail "dry-run flow failed"
fi
[ -z "$(find "$dry_root" -mindepth 1 -print -quit)" ] || fail "dry-run wrote files"
grep -Fq 'Dry-run mode: no system files will be changed.' "$work_dir/dry-run.log" ||
  fail "dry-run notice missing"
printf 'installer dry-run flow passed\n'
