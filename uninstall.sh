#!/usr/bin/env bash
# Remove the QuickStatus.dev server agent. Sends a clean "leave" first, so the console shows this
# server as removed rather than lost.
#
#   sudo bash uninstall.sh [--keep-config]
set -euo pipefail

KEEP=0
[ "${1:-}" = "--keep-config" ] && KEEP=1
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null; then
  systemctl disable --now quickstatus-agent.timer >/dev/null 2>&1 || true
  # Stopping the leave unit runs its ExecStop: the leave call.
  systemctl disable --now quickstatus-agent-leave.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/quickstatus-agent.service /etc/systemd/system/quickstatus-agent.timer \
    /etc/systemd/system/quickstatus-agent-leave.service
  systemctl daemon-reload
elif [ -x /usr/local/bin/quickstatus-agent ]; then
  runuser -u quickstatus -- /usr/local/bin/quickstatus-agent leave 2>/dev/null \
    || su -s /bin/sh quickstatus -c '/usr/local/bin/quickstatus-agent leave' 2>/dev/null || true
fi

rm -f /etc/cron.d/quickstatus-agent /usr/local/bin/quickstatus-agent
rm -rf /var/lib/quickstatus
if [ "$KEEP" = 0 ]; then
  rm -rf /etc/quickstatus
  if id quickstatus >/dev/null 2>&1; then
    userdel quickstatus 2>/dev/null || deluser quickstatus 2>/dev/null || true
  fi
  if grep -q '^quickstatus:' /etc/group; then
    groupdel quickstatus 2>/dev/null || delgroup quickstatus 2>/dev/null || true
  fi
fi
echo "==> removed the QuickStatus.dev agent"
