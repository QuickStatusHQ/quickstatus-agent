# Changelog

## 0.1.0 (2026-11-16)

- First release: CPU, memory, swap, load, disks and inodes, disk I/O, network and watched
  processes, sent as payload v1.
- Installer with token sources (flag, file, AWS SSM, AWS Secrets Manager, Google Secret
  Manager), systemd timer or cron, and a clean leave on shutdown.
- Container image with `HOST_ROOT`, and a Kubernetes DaemonSet example.
- Hardening before release:
  - The container image runs as uid 10001; the documented `docker run` and the DaemonSet drop
    all capabilities. The DaemonSet adds `RuntimeDefault` seccomp, no service-account token,
    per-pod state and a token file, and leaves control-plane nodes out by default.
  - Both systemd units share a stricter sandbox, including the leave-on-shutdown unit.
  - The installer creates the `quickstatus` group itself and refuses an existing `quickstatus`
    user that has a login shell, a regular uid or other groups, or a group others share.
  - The installer refuses a non-HTTPS `--api` (loopback is allowed for tests), any `--api` with a
    `user@` part, newlines or control characters in any setting, and a `--version` that isn't a
    release number.
  - `/etc/os-release` is parsed as text, not sourced. Cloud metadata requests never use a proxy.
  - `agent.conf` says it is a credential. The README covers `--token-file`, verified pinned
    installs and uninstalls, machine images, and process-name matching.
  - Releases publish version-tagged images only (no `:latest`); workflow actions are pinned to
    commit SHAs.
