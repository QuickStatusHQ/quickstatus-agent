# Security

Please report vulnerabilities privately to support@quickstatus.dev (subject "security"), or
through GitHub's private vulnerability reporting on this repository, rather than in a public
issue.

## What the agent is designed to guarantee

**The account.** It runs as the `quickstatus` system user: no login shell, no home directory, and
`quickstatus` as its only group. If a `quickstatus` user already exists and doesn't look like
that, or anyone else is in the `quickstatus` group, the installer stops instead of reusing it.

**The systemd sandbox.** Both units (the report and the leave-on-shutdown unit) run with
`NoNewPrivileges`, an empty `CapabilityBoundingSet`, `ProtectSystem=strict` (writable:
`/var/lib/quickstatus` only), `ProtectHome=read-only`, `PrivateTmp`, `PrivateDevices`,
`ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`,
`ProtectHostname`, `ProtectClock`, `RestrictSUIDSGID`, `RestrictNamespaces`, `RestrictRealtime`,
`LockPersonality`, `MemoryDenyWriteExecute`, `SystemCallArchitectures=native`,
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK` and `UMask=0077`. `/home` stays
read-only rather than hidden so a separate `/home` partition can still be measured. On systems
without systemd (Alpine with cron) there is no sandbox: the protection is the unprivileged account
alone.

**Containers.** The image runs as uid 10001. The documented `docker run` and the Kubernetes
DaemonSet drop every capability, forbid privilege escalation and use a read-only root filesystem;
the DaemonSet also uses the `RuntimeDefault` seccomp profile and mounts no service-account token.
The host's `/` is mounted read-only because `df` needs each host mount point. That exposes what an
unprivileged host user can read (world-readable files), but not root-only files or root-owned
sockets such as `docker.sock`.

**The token and the machine secret.** The enrollment token sits in `/etc/quickstatus/agent.conf`
(root:quickstatus, 0640). The per-machine secret sits in `/var/lib/quickstatus` (0700). The
running agent sends either one only in an `Authorization` header read from a 0600 file, never on
its command line, and only to an `https://` API (the installer refuses anything else, except a
loopback address for testing). Report requests don't follow redirects.

The install command is the exception: `--token qse_...` is on the installer's command line, so
while it runs other local users can see it in the process list, and it is kept in shell history
and the sudo log. Use `--token-file` (or `--token-aws-ssm`, `--token-aws-secret`,
`--token-gcp-secret`) to keep it off the command line.

Both files are credentials. Don't bake them into machine images (see "Machine images" in the
README).

**What a token can do.** An enrollment token can only add machines to its own check, up to the
plan's limit. It can't read data. A machine secret can send reports for, and remove, that one
machine. Getting a new install command in the console replaces the token; machines that already
enrolled keep reporting.

**Parsing, not running.** `agent.conf` is parsed as `KEY=value` lines and never sourced; the
installer refuses values with newlines or control characters. `/etc/os-release` is read as text.
Replies from the API are parsed with `sed`, never evaluated.

**Cloud metadata.** The agent reads only the instance id (IMDSv2 on AWS) and never through a
proxy, since the AWS metadata session token is valid for every metadata path.

**Downloads.** The installer checks every file it downloads against the release's `SHA256SUMS`
before installing anything. `install.sh` itself runs before any check when piped from `curl`;
the README shows how to download, verify and then run a pinned release. `SHA256SUMS` comes from
the same release, so it is not a signature, and releases and images are not signed. Images are
published under version tags only.

**Process watching** matches the 15-character kernel process name, which any local user can
reuse. It tells you a process with that name exists, nothing more. The agent never reads command
lines or environments of other processes.
