#!/usr/bin/env bash
# QuickStatus.dev server agent: reports this machine's CPU, memory, disk, network and watched
# processes to QuickStatus.dev every interval. https://github.com/QuickStatusHQ/quickstatus-agent
#
# What is sent: PAYLOAD.md. Nothing else is read: no logs, files, environment or arguments of
# other processes (only process names, for the watch list).
#
#   quickstatus-agent run [--now]   one report (the systemd timer calls this every minute)
#   quickstatus-agent loop          report forever (containers; sends leave on SIGTERM)
#   quickstatus-agent enroll        enroll now (normally automatic)
#   quickstatus-agent leave         tell QuickStatus.dev this machine is shutting down on purpose
#   quickstatus-agent status        show config, member id and the last report
#   quickstatus-agent print         print the next report without sending it
#   quickstatus-agent version
#
# Exit codes: 0 ok, 2 usage or config error, 3 unsupported system, 4 token rejected,
# 5 network or server unavailable, 7 member limit reached for this plan.

set -u
umask 077

AGENT_VERSION="0.1.0"
CONFIG_FILE="${QUICKSTATUS_CONFIG:-/etc/quickstatus/agent.conf}"
STATE_DIR="${QUICKSTATUS_STATE_DIR:-/var/lib/quickstatus}"
HOST_ROOT="${HOST_ROOT:-}"
PROC="${HOST_ROOT}/proc"
# In a container with the host's / at HOST_ROOT, /proc/self is this container: read mounts and
# interfaces through the host's init process instead (needs the host /proc, or hostPID in k8s).
if [ -n "$HOST_ROOT" ]; then NS="$PROC/1"; else NS="$PROC/self"; fi
DEFAULT_API="https://api.quickstatus.dev"
CURL_TIMEOUT=10

# Config (agent.conf is KEY=value lines; never sourced, so it can't run code).
TOKEN=""
API="$DEFAULT_API"
PROCESSES=""
SKIP_MOUNTS=""
LABELS=""
INSTANCE_KEY_OVERRIDE=""

log() { printf 'quickstatus-agent: %s\n' "$*" >&2; }

load_config() {
  if [ -r "$CONFIG_FILE" ]; then
    local key value
    while IFS='=' read -r key value || [ -n "$key" ]; do
      key="${key//[[:space:]]/}"
      case "$key" in ''|'#'*) continue ;; esac
      value="${value%$'\r'}"
      value="${value#\"}"; value="${value%\"}"
      case "$key" in
        TOKEN) TOKEN="$value" ;;
        API) API="${value%/}" ;;
        PROCESSES) PROCESSES="$value" ;;
        SKIP_MOUNTS) SKIP_MOUNTS="$value" ;;
        LABELS) LABELS="$value" ;;
        INSTANCE_KEY) INSTANCE_KEY_OVERRIDE="$value" ;;
      esac
    done < "$CONFIG_FILE"
  fi
  # Environment wins (containers, IaC).
  TOKEN="${QUICKSTATUS_TOKEN:-$TOKEN}"
  if [ -z "$TOKEN" ] && [ -n "${QUICKSTATUS_TOKEN_FILE:-}" ] && [ -r "$QUICKSTATUS_TOKEN_FILE" ]; then
    TOKEN="$(tr -d '[:space:]' < "$QUICKSTATUS_TOKEN_FILE")"
  fi
  API="${QUICKSTATUS_API:-$API}"; API="${API%/}"
  PROCESSES="${QUICKSTATUS_PROCESSES:-$PROCESSES}"
  SKIP_MOUNTS="${QUICKSTATUS_SKIP_MOUNTS:-$SKIP_MOUNTS}"
  LABELS="${QUICKSTATUS_LABELS:-$LABELS}"
  INSTANCE_KEY_OVERRIDE="${QUICKSTATUS_INSTANCE_KEY:-$INSTANCE_KEY_OVERRIDE}"
}

state_get() { [ -r "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1" 2>/dev/null; return 0; }
state_set() { printf '%s' "$2" > "$STATE_DIR/$1.tmp" && mv "$STATE_DIR/$1.tmp" "$STATE_DIR/$1"; }
state_del() { rm -f "$STATE_DIR/$1"; }

now_s() { date +%s; }

# --- JSON helpers ----------------------------------------------------------------------------

json_str() {
  # Quote a string for JSON: escape \ and ", drop control characters.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\037')"
  printf '"%s"' "$s"
}

json_num() {
  # A number or null.
  case "$1" in
    ''|*[!0-9.eE+-]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

json_field() {
  # Read a string or number field from a small flat JSON reply (no jq needed).
  local flat value
  flat="$(printf '%s' "$2" | tr -d '\n')"
  value="$(printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
  [ -n "$value" ] || value="$(printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9.]\{1,\}\).*/\1/p")"
  printf '%s' "$value"
}

# --- identity --------------------------------------------------------------------------------

imds() {
  # curl a metadata URL with short timeouts; prints the body on HTTP 200 only. Never through a
  # proxy: the AWS session token is good for every metadata path, so it must not leave the host.
  curl -fsS --noproxy '*' --connect-timeout 0.5 --max-time 1 "$@" 2>/dev/null
}

detect_instance_key() {
  if [ -n "$INSTANCE_KEY_OVERRIDE" ]; then printf '%s' "$INSTANCE_KEY_OVERRIDE"; return; fi
  if [ -n "${NODE_NAME:-}" ]; then printf 'k8s:%s' "$NODE_NAME"; return; fi
  local cloud id
  cloud="$(state_get cloud)"
  if [ "$cloud" != "none" ]; then
    if [ -z "$cloud" ] || [ "$cloud" = "aws" ]; then
      local imds_token
      imds_token="$(imds -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
      if [ -n "$imds_token" ]; then
        id="$(imds -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id)"
        if [ -n "$id" ]; then state_set cloud aws; printf 'aws:%s' "$id"; return; fi
      fi
    fi
    if [ -z "$cloud" ] || [ "$cloud" = "gcp" ]; then
      id="$(imds -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/id)"
      if [ -n "$id" ]; then state_set cloud gcp; printf 'gcp:%s' "$id"; return; fi
    fi
    if [ -z "$cloud" ] || [ "$cloud" = "azure" ]; then
      id="$(imds -H 'Metadata: true' 'http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text')"
      if [ -n "$id" ]; then state_set cloud azure; printf 'azure:%s' "$id"; return; fi
    fi
    # Not on a cloud we know: don't ask the metadata endpoints every minute.
    [ -z "$cloud" ] && state_set cloud none
  fi
  id="$(cat "${HOST_ROOT}/etc/machine-id" 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true)"
  if [ -n "$id" ]; then printf 'machine:%s' "$id"; return; fi
  printf 'host:%s' "$(host_name)"
}

host_name() {
  if [ -n "$HOST_ROOT" ]; then
    [ -n "${NODE_NAME:-}" ] && { printf '%s' "$NODE_NAME"; return; }
    [ -s "$HOST_ROOT/etc/hostname" ] && { tr -d '[:space:]' < "$HOST_ROOT/etc/hostname"; return; }
  fi
  cat "$PROC/sys/kernel/hostname" 2>/dev/null || hostname 2>/dev/null || echo unknown
}

labels_json() {
  # LABELS="env=prod,role=web" plus the cloud we detected.
  local out="" pair key value cloud
  cloud="$(state_get cloud)"
  if [ -n "$cloud" ] && [ "$cloud" != "none" ]; then out="\"cloud\":$(json_str "$cloud")"; fi
  if [ -n "${NODE_NAME:-}" ]; then out="${out:+$out,}\"k8s_node\":$(json_str "$NODE_NAME")"; fi
  local IFS=','
  for pair in $LABELS; do
    key="${pair%%=*}"; value="${pair#*=}"
    key="${key// /}"
    [ -z "$key" ] || [ "$key" = "$pair" ] && continue
    out="${out:+$out,}$(json_str "$key"):$(json_str "$value")"
  done
  printf '{%s}' "$out"
}

# --- HTTP ------------------------------------------------------------------------------------

# post PATH BEARER BODY_FILE [gzip]  ->  sets HTTP_CODE and HTTP_BODY
HTTP_CODE=""
HTTP_BODY=""
post() {
  local path="$1" bearer="$2" body="$3" encoding="${4:-}"
  local headers="$STATE_DIR/.headers" out="$STATE_DIR/.response"
  # The secret goes in a header file (mode 600), not on the command line.
  {
    printf 'Authorization: Bearer %s\n' "$bearer"
    printf 'Content-Type: application/json\n'
    printf 'User-Agent: quickstatus-agent/%s\n' "$AGENT_VERSION"
    [ -n "$encoding" ] && printf 'Content-Encoding: %s\n' "$encoding"
  } > "$headers"
  HTTP_CODE="$(curl -sS -o "$out" -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
    -H @"$headers" --data-binary @"$body" -X POST "$API$path" 2>/dev/null)" || HTTP_CODE="000"
  HTTP_BODY="$(cat "$out" 2>/dev/null || true)"
  rm -f "$headers" "$out"
}

# --- enroll / leave --------------------------------------------------------------------------

enroll() {
  if [ -z "$TOKEN" ]; then log "no enrollment token (TOKEN in $CONFIG_FILE or QUICKSTATUS_TOKEN)"; return 2; fi
  local key body="$STATE_DIR/.enroll.json"
  key="$(detect_instance_key)"
  printf '{"instance_key":%s,"hostname":%s,"labels":%s,"agent_version":%s}' \
    "$(json_str "$key")" "$(json_str "$(host_name)")" "$(labels_json)" "$(json_str "$AGENT_VERSION")" > "$body"
  post /agent/enroll "$TOKEN" "$body"
  rm -f "$body"
  case "$HTTP_CODE" in
    200)
      local secret
      secret="$(json_field secret "$HTTP_BODY")"
      if [ -z "$secret" ]; then log "enroll: unexpected reply"; return 5; fi
      state_set secret "$secret"
      state_set member_id "$(json_field member_id "$HTTP_BODY")"
      state_set instance_key "$key"
      state_set interval "$(json_field interval_s "$HTTP_BODY")"
      state_set offset "$(json_field offset_s "$HTTP_BODY")"
      log "enrolled as $(state_get member_id)"
      return 0 ;;
    401) log "enrollment token rejected; copy the install command again from the console"; return 4 ;;
    403) log "$(json_field detail "$HTTP_BODY")"; return 7 ;;
    *) log "enroll failed (HTTP $HTTP_CODE); will retry"; return 5 ;;
  esac
}

cmd_leave() {
  local secret empty="$STATE_DIR/.empty.json"
  secret="$(state_get secret)"
  [ -n "$secret" ] || return 0
  printf '{}' > "$empty"
  CURL_TIMEOUT=5 post /agent/leave "$secret" "$empty"
  rm -f "$empty"
  [ "$HTTP_CODE" = "200" ] && log "left (clean shutdown)"
  return 0
}

# --- metrics ---------------------------------------------------------------------------------

pct() {
  # pct PART TOTAL -> percent with one decimal, or empty
  awk -v p="$1" -v t="$2" 'BEGIN { if (t > 0) printf "%.1f", (p * 100) / t }'
}

collect_cpu() {
  # Diff /proc/stat against the previous run, so the numbers cover the whole interval.
  local line prev
  line="$(awk '/^cpu /{print $2+$3, $4, $5, $6, $7+$8, $9; exit}' "$PROC/stat")"
  # fields: user+nice system idle iowait irq+softirq steal
  prev="$(state_get cpu)"
  state_set cpu "$line"
  CPU_PCT=""; CPU_IOWAIT=""; CPU_STEAL=""
  [ -n "$prev" ] || return 0
  read -r u s i w q st <<< "$line"
  read -r pu ps pi pw pq pst <<< "$prev"
  local total=$(( (u - pu) + (s - ps) + (i - pi) + (w - pw) + (q - pq) + (st - pst) ))
  [ "$total" -gt 0 ] || return 0
  CPU_PCT="$(pct $(( total - (i - pi) - (w - pw) )) "$total")"
  CPU_IOWAIT="$(pct $(( w - pw )) "$total")"
  CPU_STEAL="$(pct $(( st - pst )) "$total")"
}

collect_load() {
  read -r LOAD1 LOAD5 LOAD15 _ < "$PROC/loadavg"
  CORES="$(grep -c '^processor' "$PROC/cpuinfo" 2>/dev/null || echo "")"
}

collect_mem() {
  eval "$(awk '
    /^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2}
    /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
    END {
      if (a == "") a = f
      # %.0f, not %d: BusyBox awk caps %d at 2^31.
      printf "MEM_TOTAL=%.0f MEM_AVAIL=%.0f ", t * 1024, a * 1024
      if (t > 0) printf "MEM_PCT=%.1f ", (t - a) * 100 / t; else printf "MEM_PCT= "
      if (st > 0) printf "SWAP_PCT=%.1f\n", (st - sf) * 100 / st; else printf "SWAP_PCT=0\n"
    }' "$PROC/meminfo")"
}

REAL_FS='^(ext2|ext3|ext4|xfs|btrfs|zfs|f2fs|vfat|exfat|jfs|reiserfs|ntfs|ntfs3|nfs|nfs4|cifs|overlay)$'

skip_mount() {
  local m
  for m in $SKIP_MOUNTS; do [ "$1" = "$m" ] && return 0; done
  return 1
}

collect_disks() {
  # One entry per real filesystem mount: used % and inodes used %.
  DISKS_JSON=""
  local dev mount fs rest seen=" " used inodes
  while read -r dev mount fs rest; do
    printf '%s' "$fs" | grep -Eq "$REAL_FS" || continue
    # overlay only counts as the root filesystem (containers); others are layers.
    if [ "$fs" = "overlay" ] && [ "$mount" != "/" ]; then continue; fi
    # /proc/mounts writes a space as \040; printf %b wants \0040.
    mount="$(printf '%b' "${mount//\\/\\0}")"
    # One entry per filesystem: bind mounts (and Docker's /etc/hosts files) repeat a device.
    [ -d "${HOST_ROOT}$mount" ] || continue
    case "$seen" in *" $dev "*|*" $mount "*) continue ;; esac
    seen="$seen$dev $mount "
    skip_mount "$mount" && continue
    used="$(df -P "${HOST_ROOT}$mount" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    inodes="$(df -Pi "${HOST_ROOT}$mount" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); if ($5 != "-") print $5}')"
    [ -n "$used" ] || continue
    DISKS_JSON="${DISKS_JSON:+$DISKS_JSON,}{\"mount\":$(json_str "$mount"),\"fs\":$(json_str "$fs"),\"pct\":$(json_num "$used"),\"inodes_pct\":$(json_num "$inodes")}"
  done < "$NS/mounts"
}

rates() {
  # rates NAME "key value value..." -> per-second deltas against the previous run, by key.
  # Prints "key rate1 rate2" lines. Counter resets give no rate for that run.
  local name="$1" now_lines="$2" prev elapsed
  prev="$(state_get "$name")"
  state_set "$name" "$(now_s)"$'\n'"$now_lines"
  [ -n "$prev" ] || return 0
  elapsed=$(( $(now_s) - $(printf '%s\n' "$prev" | head -n1) ))
  [ "$elapsed" -gt 0 ] || return 0
  printf '%s\n' "$prev" | tail -n +2 | NOW_LINES="$now_lines" awk -v e="$elapsed" '
    BEGIN { n = split(ENVIRON["NOW_LINES"], lines, "\n"); for (i = 1; i <= n; i++) { split(lines[i], f, " "); a[f[1]] = f[2]; b[f[1]] = f[3] } }
    { if ($1 in a && a[$1] >= $2 && b[$1] >= $3) printf "%s %.0f %.0f\n", $1, (a[$1] - $2) / e, (b[$1] - $3) / e }'
}

collect_net() {
  NET_JSON=""
  local counters
  counters="$(awk -F'[: ]+' 'NR > 2 { sub(/^ +/, ""); split($0, f, /[: ]+/);
      name = f[1]; if (name == "lo" || name ~ /^(veth|docker|br-|cni|flannel|cali|virbr|tun|tap)/) next;
      if (f[2] + f[10] == 0) next;  # tunnels and interfaces that never carried traffic
      print name, f[2], f[10] }' "$NS/net/dev")"
  local iface rx tx
  while read -r iface rx tx; do
    [ -n "$iface" ] || continue
    NET_JSON="${NET_JSON:+$NET_JSON,}{\"iface\":$(json_str "$iface"),\"rx_bps\":$rx,\"tx_bps\":$tx}"
  done <<< "$(rates net "$counters")"
}

collect_disk_io() {
  DISK_IO_JSON=""
  local counters
  # Whole disks only; sectors are 512 bytes.
  counters="$(awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ { print $3, $6 * 512, $10 * 512 }' "$PROC/diskstats" 2>/dev/null)"
  local dev r w
  while read -r dev r w; do
    [ -n "$dev" ] || continue
    DISK_IO_JSON="${DISK_IO_JSON:+$DISK_IO_JSON,}{\"device\":$(json_str "$dev"),\"read_bps\":$r,\"write_bps\":$w}"
  done <<< "$(rates diskio "$counters")"
}

collect_procs() {
  PROC_COUNT="$(find "$PROC" -maxdepth 1 -name '[0-9]*' -type d 2>/dev/null | wc -l | tr -d ' ')"
  WATCHED_JSON=""
  [ -n "$PROCESSES" ] || return 0
  local comms name short count
  comms="$(cat "$PROC"/[0-9]*/comm 2>/dev/null)"
  for name in $PROCESSES; do
    # comm is cut to 15 characters by the kernel.
    short="${name:0:15}"
    count="$(printf '%s\n' "$comms" | grep -cxF -- "$short" || true)"
    if [ "${count:-0}" -gt 0 ]; then running=true; else running=false; fi
    WATCHED_JSON="${WATCHED_JSON:+$WATCHED_JSON,}{\"name\":$(json_str "$name"),\"running\":$running,\"count\":${count:-0}}"
  done
}

os_release_value() {
  # os_release_value KEY FILE -> the value as text. Read, never sourced: the file isn't code.
  local value
  value="$(sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1)"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}"; value="${value//\\\"/\"}"; value="${value//\\\\/\\}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

collect_host() {
  local pretty file="${HOST_ROOT}/etc/os-release"
  # An absolute symlink here points outside HOST_ROOT in a container; the spec's fallback is
  # /usr/lib/os-release.
  [ -r "$file" ] || file="${HOST_ROOT}/usr/lib/os-release"
  pretty="$(os_release_value PRETTY_NAME "$file")"
  [ -n "$pretty" ] || pretty="$(os_release_value NAME "$file")"
  HOST_JSON="{\"hostname\":$(json_str "$(host_name)"),\"os\":$(json_str "${pretty:-$(uname -s)}"),\"kernel\":$(json_str "$(cat "$PROC/sys/kernel/osrelease" 2>/dev/null || uname -r)"),\"arch\":$(json_str "$(uname -m)"),\"uptime_s\":$(json_num "$(awk '{printf "%.0f", $1}' "$PROC/uptime")")}"
}

build_report() {
  local elapsed="" last
  last="$(state_get last_run)"
  [ -n "$last" ] && elapsed=$(( $(now_s) - last ))
  state_set last_run "$(now_s)"
  collect_cpu; collect_load; collect_mem; collect_disks; collect_net; collect_disk_io; collect_procs; collect_host
  printf '{"v":1,"agent":{"version":%s},"host":%s,' "$(json_str "$AGENT_VERSION")" "$HOST_JSON"
  printf '"cpu":{"pct":%s,"iowait_pct":%s,"steal_pct":%s,"load1":%s,"load5":%s,"load15":%s,"cores":%s},' \
    "$(json_num "$CPU_PCT")" "$(json_num "$CPU_IOWAIT")" "$(json_num "$CPU_STEAL")" \
    "$(json_num "$LOAD1")" "$(json_num "$LOAD5")" "$(json_num "$LOAD15")" "$(json_num "$CORES")"
  printf '"mem":{"pct":%s,"total_bytes":%s,"available_bytes":%s,"swap_pct":%s},' \
    "$(json_num "$MEM_PCT")" "$(json_num "$MEM_TOTAL")" "$(json_num "$MEM_AVAIL")" "$(json_num "$SWAP_PCT")"
  printf '"disks":[%s],"disk_io":[%s],"net":[%s],' "$DISKS_JSON" "$DISK_IO_JSON" "$NET_JSON"
  printf '"procs":{"count":%s,"watched":[%s]},"interval_s":%s}\n' "$(json_num "$PROC_COUNT")" "$WATCHED_JSON" "$(json_num "$elapsed")"
}

# --- run -------------------------------------------------------------------------------------

ensure_enrolled() {
  local key
  key="$(detect_instance_key)"
  # A cloned disk or a new instance brings someone else's state: enroll as this machine.
  if [ -n "$(state_get secret)" ] && [ "$key" = "$(state_get instance_key)" ]; then return 0; fi
  [ -n "$(state_get secret)" ] && log "machine identity changed; enrolling again"
  state_del secret
  enroll
}

cmd_run() {
  local now_flag="${1:-}"
  ensure_enrolled || return $?
  local interval offset last
  interval="$(state_get interval)"; interval="${interval:-60}"
  offset="$(state_get offset)"; offset="${offset:-0}"
  if [ "$now_flag" != "--now" ]; then
    last="$(state_get last_report)"
    # The timer fires at :00; a run must end before the next one, so cap the spread at 50 s.
    [ "$offset" -gt 50 ] && offset=50
    # Skip runs until the interval has passed (Free: 5 minutes). Judge it at the moment the
    # report would go out (after the offset sleep), or a 60 s plan reports every 2 minutes.
    if [ -n "$last" ] && [ $(( $(now_s) + offset - last )) -lt $(( interval - 15 )) ]; then return 0; fi
    sleep "$offset"
  fi
  local body="$STATE_DIR/.report.json"
  build_report > "$body"
  gzip -c "$body" > "$body.gz" && mv "$body.gz" "$body"
  post /agent/report "$(state_get secret)" "$body" gzip
  rm -f "$body"
  case "$HTTP_CODE" in
    200)
      state_set last_report "$(now_s)"
      local new
      new="$(json_field interval_s "$HTTP_BODY")"; [ -n "$new" ] && state_set interval "$new"
      new="$(json_field offset_s "$HTTP_BODY")"; [ -n "$new" ] && state_set offset "$new"
      new="$(json_field latest_version "$HTTP_BODY")"; [ -n "$new" ] && state_set latest_version "$new"
      return 0 ;;
    401)
      # Removed in the console, or re-enrolled elsewhere: enroll again on the next run.
      log "member secret rejected; enrolling again next run"
      state_del secret
      return 5 ;;
    429) return 0 ;;
    *) log "report not delivered (HTTP $HTTP_CODE)"; return 5 ;;
  esac
}

cmd_loop() {
  trap 'cmd_leave; exit 0' TERM INT
  while :; do
    cmd_run --now || true
    local interval offset
    interval="$(state_get interval)"; interval="${interval:-60}"
    offset="$(state_get offset)"; offset="${offset:-0}"
    # Sleep to the next slot (interval boundary + this machine's offset); wait in the
    # background so SIGTERM is handled at once.
    local pause=$(( interval - ($(now_s) % interval) + offset ))
    [ "$pause" -gt "$interval" ] && pause=$(( pause - interval ))
    sleep "$pause" & wait $!
  done
}

cmd_status() {
  printf 'agent      %s\n' "$AGENT_VERSION"
  printf 'config     %s\n' "$CONFIG_FILE"
  printf 'api        %s\n' "$API"
  printf 'token      %s\n' "$( [ -n "$TOKEN" ] && printf '%s…' "${TOKEN:0:10}" || printf 'not set')"
  printf 'member     %s\n' "$(state_get member_id)"
  printf 'identity   %s\n' "$(state_get instance_key)"
  printf 'interval   %ss (offset %ss)\n' "$(state_get interval)" "$(state_get offset)"
  local last; last="$(state_get last_report)"
  printf 'last sent  %s\n' "$( [ -n "$last" ] && date -d "@$last" 2>/dev/null || printf '%s' "${last:-never}")"
  local latest; latest="$(state_get latest_version)"
  if [ -n "$latest" ] && [ "$latest" != "$AGENT_VERSION" ]; then printf 'update     %s is available\n' "$latest"; fi
}

main() {
  if [ ! -r "$PROC/stat" ]; then log "this agent needs Linux /proc (HOST_ROOT=$HOST_ROOT)"; exit 3; fi
  mkdir -p "$STATE_DIR" 2>/dev/null
  if [ ! -w "$STATE_DIR" ]; then log "state directory $STATE_DIR is not writable"; exit 2; fi
  load_config
  case "${1:-run}" in
    run) cmd_run "${2:-}" ;;
    loop) cmd_loop ;;
    enroll) state_del secret; enroll ;;
    leave) cmd_leave ;;
    status) cmd_status ;;
    print) build_report ;;
    version|--version|-v) printf '%s\n' "$AGENT_VERSION" ;;
    *) printf 'usage: quickstatus-agent [run [--now]|loop|enroll|leave|status|print|version]\n' >&2; exit 2 ;;
  esac
}

main "$@"
