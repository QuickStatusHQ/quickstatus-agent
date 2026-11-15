# QuickStatus.dev server agent

A small Bash script that reports a Linux server's CPU, memory, disk, network and watched
processes to [QuickStatus.dev](https://quickstatus.dev) every minute, so you get alerted when a
server is overloaded, filling up, or stops reporting.

- One file, readable top to bottom: [`quickstatus-agent.sh`](quickstatus-agent.sh). It needs
  `bash`, `curl`, `gzip`, `awk` and `df`, which the installer adds if they're missing.
- Runs as an unprivileged `quickstatus` user from a systemd timer (cron if there's no systemd).
  No daemon and no open ports.
- Sends only the numbers in [PAYLOAD.md](PAYLOAD.md). It never reads logs or files, and of other
  processes it reads only their names.
- Built for groups. One server check covers many machines. Machines enroll themselves with the
  check's token, and a machine that is scaled in leaves cleanly instead of raising an alarm.

## Install

Create a **Server** check in the console and copy its install command:

```sh
curl -fsSL https://quickstatus.dev/agent/install.sh | sudo bash -s -- --token qse_...
```

`--token` puts the token on the command line, so while the installer runs other local users can
see it in the process list, and it lands in your shell history and sudo log. To keep it off the
command line, put it in a file only root can read and pass `--token-file`:

```sh
sudo sh -c 'umask 077; cat > /root/qs-token'   # paste the token, Enter, then Ctrl-D
curl -fsSL https://quickstatus.dev/agent/install.sh | sudo bash -s -- --token-file /root/qs-token
```

Both work the same way. A token can only add servers to its own check; if one leaks, get a new
install command in the console (servers already reporting keep working).

The installer sends a first report before it finishes, so a wrong token fails right there and
isn't left silently retrying. Supported systems: Ubuntu, Debian, RHEL/Rocky/Alma, Amazon Linux,
Alpine and openSUSE, on x86_64 and arm64.

| Option | |
|---|---|
| `--token TOKEN` | Enrollment token (or set `QUICKSTATUS_TOKEN`). Visible in the process list while the installer runs |
| `--token-file PATH` | Read the token from a file (keeps it off the command line) |
| `--token-aws-ssm NAME` | Read it from AWS SSM Parameter Store (SecureString works) |
| `--token-aws-secret ID` | Read it from AWS Secrets Manager |
| `--token-gcp-secret NAME` | Read it from Google Secret Manager |
| `--labels env=prod,role=web` | Labels shown in the console |
| `--processes "nginx postgres"` | Processes to watch (for "process not running" alerts; see below) |
| `--version X.Y.Z` | Install a specific release (pin this in IaC) |
| `--wait` | Fail the install if the first report isn't accepted |
| `--no-start` | Install and configure only |

Running the installer again upgrades the agent and keeps the settings you don't pass, so
`install.sh --token qse_new` alone rotates the token.

### Verified install

`curl | sudo bash` runs `install.sh` as root before anything is checked; the installer then checks
the files it downloads against the release's `SHA256SUMS`. To check `install.sh` itself first,
pin a release and verify it:

```sh
v=0.1.0
base=https://github.com/QuickStatusHQ/quickstatus-agent/releases/download/v$v
curl -fsSLO "$base/install.sh" -fsSLO "$base/SHA256SUMS"
grep ' install.sh$' SHA256SUMS | sha256sum -c -
sudo bash install.sh --version "$v" --token-file /root/qs-token
```

`SHA256SUMS` comes from the same GitHub release as the files, so it proves they match each other
and that you got them from GitHub over HTTPS. It is not a signature, and releases aren't signed.
`QUICKSTATUS_RELEASE_BASE` (download from a mirror) moves both the files and `SHA256SUMS` to that
mirror, so it gives up the GitHub guarantee.

### Autoscaling groups, Terraform, CloudFormation, Pulumi

Put the install command in the launch template's user data. Every instance enrolls with the
same token and identifies itself by its cloud instance id. When an instance shuts down it tells
QuickStatus.dev it is leaving. A machine that just stops reporting counts as lost.

```hcl
user_data = <<-EOT
  #!/bin/bash
  curl -fsSL https://quickstatus.dev/agent/install.sh | bash -s -- \
    --token-aws-ssm /quickstatus/web-token --version 0.1.0 --labels env=prod,role=web
EOT
```

Keep the token in SSM or Secrets Manager rather than in the user data. User data is readable
by anything on the instance that can reach the metadata endpoint.

### Machine images (AMIs, snapshots, VM templates)

Install the agent at boot (user data, cloud-init) rather than baking it into an image.
`/etc/quickstatus/agent.conf` holds the token and `/var/lib/quickstatus/secret` holds this
machine's secret; treat both like SSH host keys. An image or snapshot must contain neither. Take
it before the agent is installed, or run `uninstall.sh` (without `--keep-config`) first:
`--keep-config` keeps `/etc/quickstatus/agent.conf`, and with it the token.

A clone on AWS, GCP or Azure gets a new instance id and enrolls as a new server. A VM template
clone keeps `/etc/machine-id`, so clear it in the template (`truncate -s 0 /etc/machine-id`;
systemd makes a new one on first boot), or two clones report as one server.

### Docker and Kubernetes

```sh
docker run -d --name quickstatus-agent --restart unless-stopped \
  --cap-drop ALL --security-opt no-new-privileges --read-only \
  -e QUICKSTATUS_TOKEN=qse_... -v /:/host:ro -v quickstatus:/var/lib/quickstatus \
  ghcr.io/quickstatushq/quickstatus-agent:0.1.0
```

The image runs as uid 10001, not root. The host's `/` is mounted read-only because the agent
measures each host filesystem with `df`, which needs the mount point. With no capabilities and a
non-root uid it can read only what an unprivileged host user can: not root-only files (keys,
credentials) and not root's sockets (`docker.sock`). Use a version tag; there is no `:latest`.
To keep the token out of `docker inspect`, mount a file and set `QUICKSTATUS_TOKEN_FILE` instead.

For Kubernetes, run it as a DaemonSet: [`deploy/kubernetes/daemonset.yaml`](deploy/kubernetes/daemonset.yaml).
Each node is one member, named after the node. The pod runs as uid 10001 with every capability
dropped, the `RuntimeDefault` seccomp profile and no service-account token. It runs on worker
nodes only; uncomment the toleration to watch control-plane nodes too.

It mounts the node's `/` and `/proc` as `hostPath` volumes, because `df` needs each node mount
point. The Baseline and Restricted Pod Security Standards forbid `hostPath`, so in a namespace
that enforces either one the DaemonSet is accepted but its pods are rejected. The manifest's
namespace has a commented-out `pod-security.kubernetes.io/enforce: privileged` label that relaxes
Pod Security Admission for that namespace only.

GKE Autopilot rejects these `hostPath` mounts through its own admission policy, which ignores that
label. There, and on any cluster that blocks `hostPath` another way, use the installer on each
node instead: it needs no mounts.

## Commands

```
quickstatus-agent status   config, member id, last report, available update
quickstatus-agent print    the report it would send next, without sending it
quickstatus-agent run --now
quickstatus-agent leave    mark this machine as removed on purpose
```

Settings live in `/etc/quickstatus/agent.conf` (`TOKEN`, `API`, `LABELS`, `PROCESSES`,
`SKIP_MOUNTS`, `INSTANCE_KEY`). Environment variables `QUICKSTATUS_*` override them. The file is
read as `KEY=value` lines and never run as a script.

**Watched processes** match on the process name the kernel keeps (`/proc/PID/comm`), which is cut
to 15 characters. Any local user can start a process with that name, so "running" means a process
with that name exists, not that it's the real service. The agent never reads command lines or
environments of other processes.

## Uninstall

```sh
v=0.1.0
base=https://github.com/QuickStatusHQ/quickstatus-agent/releases/download/v$v
curl -fsSLO "$base/uninstall.sh" -fsSLO "$base/SHA256SUMS"
grep ' uninstall.sh$' SHA256SUMS | sha256sum -c - && sudo bash uninstall.sh
```

## How it reports

- **Identity.** It uses, in order: `INSTANCE_KEY`, the Kubernetes node name, the AWS, GCP or
  Azure instance id (IMDSv2 on AWS), then `/etc/machine-id`. A clone that gets a new cloud
  instance id enrolls as a new server; a VM clone that keeps `/etc/machine-id` reports as the same
  server (see [Machine images](#machine-images-amis-snapshots-vm-templates)).
- **Schedule.** The timer fires every minute. The agent skips runs until your plan's interval
  has passed, then waits a per-machine offset of 0–50 s so a fleet doesn't report all at once.
  The server decides the interval, so a plan change needs no agent change.
- **Rates.** CPU %, disk I/O and network are measured over the time since the previous run.
  The first report after install has no CPU %.
- **Failure.** A report that can't be delivered is dropped, not queued. A rejected secret
  (the machine was removed in the console) makes the agent enroll again on its next run.

## Development

```sh
tests/run.sh                     # install tests on Ubuntu, Debian, Alpine and Rocky (Docker)
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable *.sh tests/*.sh
```

The tests run each distro against `tests/stub_server.py`, which checks every report against
[`schema/payload.v1.json`](schema/payload.v1.json).

MIT licensed. Report security issues as described in [SECURITY.md](SECURITY.md).
