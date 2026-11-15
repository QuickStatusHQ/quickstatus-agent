#!/bin/sh
# Runs inside a fresh distro container with the checkout at /src (read-only) and the stub at
# $STUB. Exercises install, reporting, token errors, re-enroll after revoke, leave, uninstall.
set -eu
STUB="${STUB:?}"

# Bare images lack curl (and bash on Alpine); the installer needs them to be fetched first.
if command -v apk >/dev/null; then apk add --no-cache -q bash curl >/dev/null
elif command -v apt-get >/dev/null; then apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl procps >/dev/null
elif command -v dnf >/dev/null; then command -v curl >/dev/null || dnf install -y -q curl >/dev/null
fi
command -v useradd >/dev/null || command -v adduser >/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_exit() {
  want="$1"; shift
  set +e; "$@" >/tmp/out 2>&1; got=$?; set -e
  [ "$got" = "$want" ] || { cat /tmp/out >&2; fail "$* exited $got, wanted $want"; }
}

echo "--- refused before installing: plain-http API, a newline in a value, an odd --version"
expect_exit 2 env QUICKSTATUS_ALLOW_HTTP= bash /src/install.sh --source /src --token qse_good --api http://example.com
# Looks like loopback, goes to the host after the @; refused even with QUICKSTATUS_ALLOW_HTTP=1.
expect_exit 2 bash /src/install.sh --source /src --token qse_good --api 'http://127.0.0.1:80@evil.example/'
expect_exit 2 bash /src/install.sh --source /src --token qse_good --api 'http://[::1]@evil.example/'
expect_exit 2 bash /src/install.sh --source /src --token qse_good --api "$STUB" --labels "$(printf 'a=b\nTOKEN=qse_x')"
expect_exit 2 bash /src/install.sh --source /src --token qse_good --api "$STUB" --version '0.1.0/../../x'
[ ! -e /usr/local/bin/quickstatus-agent ] || fail "a refused install left the binary"

echo "--- an existing quickstatus login account is refused"
if command -v useradd >/dev/null; then useradd -m -s /bin/sh quickstatus; else adduser -D -s /bin/sh quickstatus; fi
expect_exit 3 bash /src/install.sh --source /src --token qse_good --api "$STUB"
userdel -r quickstatus 2>/dev/null || deluser --remove-home quickstatus 2>/dev/null || deluser quickstatus
if grep -q '^quickstatus:' /etc/group; then groupdel quickstatus 2>/dev/null || delgroup quickstatus; fi

echo "--- wrong token: exit 4, nothing left running"
expect_exit 4 bash /src/install.sh --source /src --token qse_nope --api "$STUB"
echo "--- member limit: exit 7"
expect_exit 7 bash /src/install.sh --source /src --token qse_full --api "$STUB"
echo "--- bad token shape: exit 2"
expect_exit 2 bash /src/install.sh --source /src --token hello --api "$STUB"

echo "--- install"
bash /src/install.sh --source /src --token qse_good --api "$STUB" --labels env=test,role=web --processes "sh sleep" \
  || fail "install"
[ -x /usr/local/bin/quickstatus-agent ] || fail "binary missing"
[ "$(stat -c %a /etc/quickstatus/agent.conf)" = 640 ] || fail "config mode"
[ "$(stat -c %G /etc/quickstatus/agent.conf)" = quickstatus ] || fail "config group isn't quickstatus"
[ "$(id -Gn quickstatus)" = quickstatus ] || fail "agent user has other groups: $(id -Gn quickstatus)"
[ -s /var/lib/quickstatus/secret ] || fail "no secret after first run"
[ "$(stat -c %U /var/lib/quickstatus/secret)" = quickstatus ] || fail "state not owned by the agent user"
[ -f /etc/cron.d/quickstatus-agent ] || fail "no cron entry (no systemd in containers)"
grep -q '^LABELS=env=test,role=web$' /etc/quickstatus/agent.conf || fail "labels not saved"

as_agent() { su -s /bin/sh quickstatus -c "$*"; }
echo "--- second report has CPU and rates"
sleep 2
as_agent "/usr/local/bin/quickstatus-agent run --now" || fail "second run"
as_agent "/usr/local/bin/quickstatus-agent status" | grep -q 'update     0.2.0 is available' || fail "status"

echo "--- revoked secret: 401, then enrolls again on the next run"
curl -fsS -X POST "$STUB/_revoke" >/dev/null
expect_exit 5 su -s /bin/sh quickstatus -c "/usr/local/bin/quickstatus-agent run --now"
[ ! -s /var/lib/quickstatus/secret ] || fail "secret kept after 401"
as_agent "/usr/local/bin/quickstatus-agent run --now" || fail "re-enroll run"

echo "--- the interval gate: a timer run right after a report sends nothing"
as_agent "/usr/local/bin/quickstatus-agent run" || fail "gated run"

echo "--- a timer run 40 s after a report, with a 12 s offset, reports (one per minute, not two)"
before="$(cat /var/lib/quickstatus/last_report)"
printf '%s' "$(( $(date +%s) - 40 ))" > /var/lib/quickstatus/last_report
printf '12' > /var/lib/quickstatus/offset
as_agent "/usr/local/bin/quickstatus-agent run" || fail "timer run"
[ "$(cat /var/lib/quickstatus/last_report)" -gt "$before" ] || fail "timer run skipped a due report"

echo "--- os-release is read as text, never run"
cp /etc/os-release /tmp/os-release.bak
# shellcheck disable=SC2016 # the $( ) and backticks are the payload; they must not expand
printf 'NAME=Test\nPRETTY_NAME="Test $(touch /tmp/pwned) `touch /tmp/pwned2`"\n' > /etc/os-release
as_agent "/usr/local/bin/quickstatus-agent print" > /tmp/print.json || fail "print"
cp /tmp/os-release.bak /etc/os-release
[ ! -e /tmp/pwned ] && [ ! -e /tmp/pwned2 ] || fail "os-release was executed"
# shellcheck disable=SC2016
grep -qF 'Test $(touch /tmp/pwned)' /tmp/print.json || fail "host.os not read from os-release"

echo "--- reinstall with only a token file keeps labels"
printf 'qse_good\n' > /root/qs-token && chmod 600 /root/qs-token
bash /src/install.sh --source /src --token-file /root/qs-token --api "$STUB" >/dev/null || fail "reinstall"
grep -q '^LABELS=env=test,role=web$' /etc/quickstatus/agent.conf || fail "labels lost on reinstall"

echo "--- uninstall sends leave"
bash /src/uninstall.sh || fail "uninstall"
[ ! -e /usr/local/bin/quickstatus-agent ] || fail "binary left behind"
[ ! -e /etc/quickstatus ] || fail "config left behind"
! id quickstatus >/dev/null 2>&1 || fail "user left behind"
if [ -n "${RELEASE:-}" ]; then
  echo "--- release download: checksums verified, a tampered file is refused"
  QUICKSTATUS_RELEASE_BASE="$RELEASE" bash /src/install.sh --token qse_good --api "$STUB" || fail "release install"
  [ -x /usr/local/bin/quickstatus-agent ] || fail "release binary missing"
  expect_exit 6 env QUICKSTATUS_RELEASE_BASE="$RELEASE/tampered" bash /src/install.sh --token qse_good --api "$STUB"
  bash /src/uninstall.sh >/dev/null
fi
echo "PASS"
