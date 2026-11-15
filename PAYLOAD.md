# What the agent sends

One gzip-compressed JSON report per interval to `POST /agent/report`. The schema is
[`schema/payload.v1.json`](schema/payload.v1.json), and [`examples/`](examples) holds real
reports. You can see the exact report for your machine with `quickstatus-agent print`.

| Field | From | Notes |
|---|---|---|
| `host.hostname`, `os`, `kernel`, `arch`, `uptime_s` | `/proc/sys/kernel`, `/etc/os-release`, `uname` | |
| `cpu.pct`, `iowait_pct`, `steal_pct` | `/proc/stat` | Over the time since the previous report; `null` on the first |
| `cpu.load1/5/15`, `cores` | `/proc/loadavg`, `/proc/cpuinfo` | |
| `mem.pct`, `total_bytes`, `available_bytes`, `swap_pct` | `/proc/meminfo` | Used = total − MemAvailable |
| `disks[]`: `mount`, `fs`, `pct`, `inodes_pct` | `/proc/mounts`, `df` | Real filesystems only, one per device; `SKIP_MOUNTS` leaves some out |
| `disk_io[]`: `device`, `read_bps`, `write_bps` | `/proc/diskstats` | Whole disks only |
| `net[]`: `iface`, `rx_bps`, `tx_bps` | `/proc/net/dev` | Skips loopback, container bridges and veths, and interfaces with no traffic |
| `procs.count` | `/proc` | |
| `procs.watched[]`: `name`, `running`, `count` | `/proc/*/comm` | Only the names in `PROCESSES`; matched on the kernel's 15-character process name, which any local user can reuse |
| `interval_s` | | Seconds covered by the rates |

Enrollment (`POST /agent/enroll`, once per machine) also sends the machine identity
(`instance_key`, for example `aws:i-0abc…`), the hostname, your `LABELS`, and the agent
version.

## Compatibility

`v` is the payload version. Within v1, changes are additive. The server ignores fields it
doesn't know, and no field added later becomes required, because agents don't update
themselves. A breaking change would be `v: 2`, and the server keeps accepting v1.
