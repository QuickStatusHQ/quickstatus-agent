#!/usr/bin/env bash
# Install the QuickStatus.dev server agent.
#
#   curl -fsSL https://quickstatus.dev/agent/install.sh | sudo bash -s -- --token qse_...
#   curl -fsSL https://quickstatus.dev/agent/install.sh | sudo bash -s -- --token-file /root/qs-token
#
# Options:
#   --token TOKEN            enrollment token from the console (or QUICKSTATUS_TOKEN). While the
#                            installer runs, other local users can see it in the process list.
#   --token-file PATH        read the token from a file (keeps it off the command line)
#   --token-aws-ssm NAME     read it from AWS SSM Parameter Store (SecureString is fine)
#   --token-aws-secret ID    read it from AWS Secrets Manager
#   --token-gcp-secret NAME  read it from Google Secret Manager (latest version)
#   --api URL                API base, https:// only (default https://api.quickstatus.dev)
#   --version X.Y.Z          install this release instead of the latest
#   --labels k=v,k=v         labels for this server (shown in the console, used by rules)
#   --processes "a b"        process names to watch (process_missing rules)
#   --no-start               install and configure, but don't start reporting
#   --wait                   fail unless the first report is accepted (for IaC)
#   --source DIR             install from a local checkout (development)
#
# Exit codes: 0 ok, 2 usage, 3 unsupported system, 4 token rejected, 5 network,
# 6 checksum mismatch, 7 member limit reached.
#
# QUICKSTATUS_RELEASE_BASE=URL downloads from a mirror instead of GitHub. SHA256SUMS then comes
# from that mirror too, so it proves the files match each other, not that they came from GitHub.

set -euo pipefail
umask 022

REPO="QuickStatusHQ/quickstatus-agent"
BIN=/usr/local/bin/quickstatus-agent
CONF_DIR=/etc/quickstatus
CONF="$CONF_DIR/agent.conf"
STATE_DIR=/var/lib/quickstatus
UNIT_DIR=/etc/systemd/system
USER_NAME=quickstatus

TOKEN="${QUICKSTATUS_TOKEN:-}"
TOKEN_FILE="" TOKEN_SSM="" TOKEN_AWS_SECRET="" TOKEN_GCP_SECRET=""
API="" VERSION="" LABELS="" PROCESSES="" SOURCE=""
START=1 WAIT=0

say() { printf '==> %s\n' "$*"; }
die() { local code="$1"; shift; printf 'quickstatus install: %s\n' "$*" >&2; exit "$code"; }

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die 2 "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --token) need_value "$@"; TOKEN="$2"; shift 2 ;;
    --token-file) need_value "$@"; TOKEN_FILE="$2"; shift 2 ;;
    --token-aws-ssm) need_value "$@"; TOKEN_SSM="$2"; shift 2 ;;
    --token-aws-secret) need_value "$@"; TOKEN_AWS_SECRET="$2"; shift 2 ;;
    --token-gcp-secret) need_value "$@"; TOKEN_GCP_SECRET="$2"; shift 2 ;;
    --api) need_value "$@"; API="${2%/}"; shift 2 ;;
    --version) need_value "$@"; VERSION="${2#v}"; shift 2 ;;
    --labels) need_value "$@"; LABELS="$2"; shift 2 ;;
    --processes) need_value "$@"; PROCESSES="$2"; shift 2 ;;
    --no-start) START=0; shift ;;
    --wait) WAIT=1; shift ;;
    --source) need_value "$@"; SOURCE="$2"; shift 2 ;;
    -h|--help) sed -n '/^set -euo/q; 2,$p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die 2 "unknown option $1 (see --help)" ;;
  esac
done

[ "$(id -u)" = 0 ] || die 2 "run as root (sudo bash -s -- ...)"

# --- values that go into the download URL and agent.conf --------------------------------------

if [ -n "$VERSION" ] && ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die 2 "--version takes a release number like 0.1.0"
fi
[ "$(uname -s)" = Linux ] || die 3 "the agent runs on Linux only"
[ -r /proc/stat ] || die 3 "/proc is not mounted"

# --- the token -------------------------------------------------------------------------------

if [ -n "$TOKEN_FILE" ]; then
  [ -r "$TOKEN_FILE" ] || die 2 "can't read $TOKEN_FILE"
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
elif [ -n "$TOKEN_SSM" ]; then
  command -v aws >/dev/null || die 2 "--token-aws-ssm needs the aws CLI"
  TOKEN="$(aws ssm get-parameter --name "$TOKEN_SSM" --with-decryption --query Parameter.Value --output text)" \
    || die 4 "couldn't read SSM parameter $TOKEN_SSM (does the instance role allow ssm:GetParameter?)"
elif [ -n "$TOKEN_AWS_SECRET" ]; then
  command -v aws >/dev/null || die 2 "--token-aws-secret needs the aws CLI"
  TOKEN="$(aws secretsmanager get-secret-value --secret-id "$TOKEN_AWS_SECRET" --query SecretString --output text)" \
    || die 4 "couldn't read secret $TOKEN_AWS_SECRET (does the instance role allow secretsmanager:GetSecretValue?)"
elif [ -n "$TOKEN_GCP_SECRET" ]; then
  command -v gcloud >/dev/null || die 2 "--token-gcp-secret needs gcloud"
  TOKEN="$(gcloud secrets versions access latest --secret="$TOKEN_GCP_SECRET")" \
    || die 4 "couldn't read secret $TOKEN_GCP_SECRET (does the service account have secretAccessor?)"
fi
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
case "$TOKEN" in
  qse_?*) ;;
  '') die 2 "no enrollment token: pass --token (copy the install command from the console)" ;;
  *) die 2 "that doesn't look like an enrollment token (they start with qse_)" ;;
esac
case "$TOKEN" in *[!A-Za-z0-9_-]*) die 2 "the token has characters a token never has; copy it again" ;; esac

# --- settings (checked before anything is installed) ----------------------------------------

# A reinstall keeps the settings it isn't given, so `install.sh --token` alone rotates the token.
old() { [ -r "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | tail -n1 || true; }
[ -n "$API" ] || API="$(old API)"
[ -n "$LABELS" ] || LABELS="$(old LABELS)"
[ -n "$PROCESSES" ] || PROCESSES="$(old PROCESSES)"
SKIP_MOUNTS="$(old SKIP_MOUNTS)"
INSTANCE_KEY="$(old INSTANCE_KEY)"
API="${API:-https://api.quickstatus.dev}"
# agent.conf is one KEY=value per line: a newline in a value would add a line (another API= or
# TOKEN=), so control characters are refused outright.
for pair in "API=$API" "LABELS=$LABELS" "PROCESSES=$PROCESSES" "SKIP_MOUNTS=$SKIP_MOUNTS" "INSTANCE_KEY=$INSTANCE_KEY"; do
  case "$pair" in *[[:cntrl:]]*) die 2 "${pair%%=*} can't contain newlines or control characters" ;; esac
done
# The token is sent to the API, so it must be HTTPS. Plain http is allowed for a loopback test
# server, or anywhere with QUICKSTATUS_ALLOW_HTTP=1 (test rigs only). No user@ part, ever: curl
# sends to the host after the @, so http://127.0.0.1:80@example.com isn't loopback.
case "$API" in
  *[[:space:]]*) die 2 "--api can't contain spaces" ;;
  *@*) die 2 "--api can't contain @ (a user@host URL sends the token to that host)" ;;
  https://?*) ;;
  http://127.0.0.1|http://127.0.0.1[:/]*|http://localhost|http://localhost[:/]*|http://\[::1\]|http://\[::1\][:/]*) ;;
  http://?*) [ "${QUICKSTATUS_ALLOW_HTTP:-}" = 1 ] || die 2 "--api must be an https:// URL (the token is sent to it)" ;;
  *) die 2 "--api must be an https:// URL" ;;
esac

# --- dependencies ----------------------------------------------------------------------------

missing=""
for tool in bash curl gzip awk sed df find; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if ! command -v useradd >/dev/null && ! command -v adduser >/dev/null; then missing="$missing useradd"; fi
# The first report runs as the agent user (bare amazonlinux:2023 has neither).
if ! command -v runuser >/dev/null && ! command -v su >/dev/null; then missing="$missing runuser"; fi
if [ -n "$missing" ]; then
  say "installing:$missing"
  # Only what's missing (Rocky ships curl-minimal, which conflicts with the curl package).
  packages=""
  for tool in $missing; do
    case "$tool" in
      awk) packages="$packages gawk" ;;
      df) packages="$packages coreutils" ;;
      find) packages="$packages findutils" ;;
      useradd)
        if command -v apt-get >/dev/null; then packages="$packages passwd"
        elif command -v zypper >/dev/null || command -v apk >/dev/null; then packages="$packages shadow"
        else packages="$packages shadow-utils"; fi ;;
      runuser) packages="$packages util-linux" ;;
      *) packages="$packages $tool" ;;
    esac
  done
  # shellcheck disable=SC2086 # $packages is a word list
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $packages >/dev/null
  elif command -v dnf >/dev/null; then dnf install -y -q $packages >/dev/null
  elif command -v microdnf >/dev/null; then microdnf install -y $packages >/dev/null
  elif command -v yum >/dev/null; then yum install -y -q $packages >/dev/null
  elif command -v apk >/dev/null; then apk add --no-cache -q $packages >/dev/null
  elif command -v zypper >/dev/null; then zypper -q -n install $packages >/dev/null
  else die 3 "please install:$missing"
  fi || die 3 "couldn't install:$packages"
fi

# --- files -----------------------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FILES="quickstatus-agent.sh quickstatus-agent.service quickstatus-agent.timer quickstatus-agent-leave.service"

if [ -n "$SOURCE" ]; then
  say "installing from $SOURCE"
  cp "$SOURCE/quickstatus-agent.sh" "$WORK/"
  cp "$SOURCE"/systemd/*.service "$SOURCE"/systemd/*.timer "$WORK/"
else
  if [ -n "${QUICKSTATUS_RELEASE_BASE:-}" ]; then
    base="$QUICKSTATUS_RELEASE_BASE"  # mirrors, tests
    say "downloading from $base (QUICKSTATUS_RELEASE_BASE); SHA256SUMS comes from there too"
  elif [ -n "$VERSION" ]; then base="https://github.com/$REPO/releases/download/v$VERSION"
  else base="https://github.com/$REPO/releases/latest/download"; fi
  say "downloading the agent ${VERSION:-(latest)}"
  for f in $FILES SHA256SUMS; do
    curl -fsSL --retry 3 --max-time 30 -o "$WORK/$f" "$base/$f" || die 5 "download failed: $base/$f"
  done
  command -v sha256sum >/dev/null || die 3 "sha256sum is needed to verify the download"
  # Every file must be listed and match; a file missing from SHA256SUMS fails too.
  for f in $FILES; do
    want="$(awk -v f="$f" '$2 == f || $2 == "*" f { print $1; exit }' "$WORK/SHA256SUMS")"
    got="$(sha256sum "$WORK/$f" | awk '{print $1}')"
    [ -n "$want" ] && [ "$want" = "$got" ] || die 6 "checksum mismatch for $f; nothing was installed"
  done
fi

# --- the account -------------------------------------------------------------------------------
# A system user with no login shell, whose primary (and only) group is quickstatus: the units say
# Group=quickstatus and agent.conf is root:quickstatus 0640, so nobody else may share that group.

GROUP_NAME="$USER_NAME"
NOLOGIN=""
for shell in /usr/sbin/nologin /sbin/nologin /bin/false; do
  [ -x "$shell" ] && { NOLOGIN="$shell"; break; }
done
[ -n "$NOLOGIN" ] || die 3 "no nologin shell found (/usr/sbin/nologin, /sbin/nologin or /bin/false)"

if ! grep -q "^$GROUP_NAME:" /etc/group; then
  groupadd --system "$GROUP_NAME" 2>/dev/null || groupadd -r "$GROUP_NAME" 2>/dev/null \
    || addgroup -S "$GROUP_NAME" || die 3 "couldn't create group $GROUP_NAME"
fi
if id "$USER_NAME" >/dev/null 2>&1; then
  uid="$(id -u "$USER_NAME")"
  login_shell="$(awk -F: -v u="$USER_NAME" '$1 == u { print $7; exit }' /etc/passwd)"
  uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)"
  why=""
  [ "$uid" -lt "${uid_min:-1000}" ] || why="it isn't a system account (uid $uid)"
  case "$login_shell" in */nologin|*/false) ;; *) why="${why:+$why; }its shell is ${login_shell:-empty}" ;; esac
  [ "$(id -gn "$USER_NAME")" = "$GROUP_NAME" ] || why="${why:+$why; }its primary group is $(id -gn "$USER_NAME")"
  [ "$(id -Gn "$USER_NAME")" = "$GROUP_NAME" ] || why="${why:+$why; }it is in other groups ($(id -Gn "$USER_NAME"))"
  [ -z "$why" ] || die 3 "a user named $USER_NAME already exists and can't hold the token: $why. Remove it, or fix it, and run this again."
else
  say "creating user $USER_NAME"
  if command -v useradd >/dev/null; then
    useradd --system --no-create-home --home-dir "$STATE_DIR" --shell "$NOLOGIN" --gid "$GROUP_NAME" "$USER_NAME" 2>/dev/null \
      || useradd -r -M -d "$STATE_DIR" -s "$NOLOGIN" -g "$GROUP_NAME" "$USER_NAME"
  else
    adduser -S -D -H -h "$STATE_DIR" -s "$NOLOGIN" -G "$GROUP_NAME" "$USER_NAME"
  fi
fi
# Nobody else in the group: not as a listed member, not as a primary group.
gid="$(awk -F: -v g="$GROUP_NAME" '$1 == g { print $3; exit }' /etc/group)"
others="$(awk -F: -v g="$GROUP_NAME" -v u="$USER_NAME" '$1 == g { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] != "" && m[i] != u) print m[i] }' /etc/group)"
others="$others $(awk -F: -v gid="$gid" -v u="$USER_NAME" '$4 == gid && $1 != u { print $1 }' /etc/passwd)"
others="$(printf '%s' "$others" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
[ -z "$others" ] || die 3 "group $GROUP_NAME also has $others, who could read the token. Remove them from it and run this again."

install -m 0755 "$WORK/quickstatus-agent.sh" "$BIN"
install -d -m 0750 -o root -g "$GROUP_NAME" "$CONF_DIR"
install -d -m 0700 -o "$USER_NAME" -g "$GROUP_NAME" "$STATE_DIR"

if [ -r "$CONF" ] && [ "$(old TOKEN)" != "$TOKEN" ]; then
  # A different token is another check (or a rotated one): enroll again with it.
  rm -f "$STATE_DIR/secret"
fi

tmp_conf="$(mktemp "$CONF_DIR/.agent.conf.XXXXXX")"
{
  echo "# QuickStatus.dev server agent. Reinstalling keeps these unless you pass new values."
  echo "# This file is a credential: TOKEN adds machines to your check. Don't bake it (or"
  echo "# /var/lib/quickstatus) into machine images; install the agent at boot instead."
  echo "TOKEN=$TOKEN"
  echo "API=$API"
  echo "LABELS=$LABELS"
  echo "# Space-separated process names to watch, e.g. PROCESSES=nginx postgres"
  echo "PROCESSES=$PROCESSES"
  echo "# Space-separated mount points to leave out, e.g. SKIP_MOUNTS=/mnt/scratch"
  echo "SKIP_MOUNTS=$SKIP_MOUNTS"
  echo "# Override the machine identity (normally the cloud instance id or /etc/machine-id)"
  echo "INSTANCE_KEY=$INSTANCE_KEY"
} > "$tmp_conf"
chown "root:$GROUP_NAME" "$tmp_conf"
chmod 0640 "$tmp_conf"
mv "$tmp_conf" "$CONF"

as_agent() {
  if command -v runuser >/dev/null; then runuser -u "$USER_NAME" -- "$@"
  else su -s /bin/sh "$USER_NAME" -c "$(printf '%q ' "$@")"
  fi
}

has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null; }

if has_systemd; then
  install -m 0644 "$WORK/quickstatus-agent.service" "$WORK/quickstatus-agent.timer" \
    "$WORK/quickstatus-agent-leave.service" "$UNIT_DIR/"
  systemctl daemon-reload
fi
rm -f /etc/cron.d/quickstatus-agent

schedule() {
  if has_systemd; then
    systemctl enable --now quickstatus-agent.timer quickstatus-agent-leave.service >/dev/null 2>&1
  else
    say "no systemd; reporting from cron"
    mkdir -p /etc/cron.d
    printf '# QuickStatus.dev server agent\n* * * * * %s %s run >/dev/null 2>&1\n' "$USER_NAME" "$BIN" > /etc/cron.d/quickstatus-agent
    chmod 0644 /etc/cron.d/quickstatus-agent
  fi
}

if [ "$START" = 0 ]; then
  say "installed; not started (--no-start). Start with: systemctl enable --now quickstatus-agent.timer quickstatus-agent-leave.service"
  exit 0
fi

# First report now: a wrong token fails here, at install time, instead of silently later.
say "sending the first report"
set +e
as_agent "$BIN" run --now
code=$?
set -e
case "$code" in
  0) say "reporting. This server shows up in the console within a minute." ;;
  4) die 4 "the enrollment token was rejected; copy the install command again from the console" ;;
  7) die 7 "this check has reached its server limit for your plan" ;;
  126|127) die 3 "couldn't run the agent as $USER_NAME (exit $code)" ;;
  *) if [ "$WAIT" = 1 ]; then die 5 "the first report wasn't accepted (exit $code)"; fi
     say "the first report didn't go through (exit $code); the agent keeps retrying every minute" ;;
esac
# Scheduled only now: a rejected token leaves nothing retrying in the background.
schedule
exit 0
