# CLAUDE.md

Public repo. Don't put private context here: no customer names, internal URLs, or notes about
the QuickStatus.dev backend beyond the public API in PAYLOAD.md.

- The agent is one Bash file. It must run on Bash 4+, GNU and BusyBox userlands (Alpine), with
  no jq or python. awk: use `%.0f`, not `%d` (BusyBox caps `%d` at 2^31).
- Payload changes are additive within v1 (PAYLOAD.md). Update `schema/payload.v1.json` and
  `examples/` in the same change; the QuickStatus.dev server vendors both.
- Before a change is done: `tests/run.sh` (Docker, the six distros CI runs) and shellcheck clean.
- Version lives in `AGENT_VERSION` in quickstatus-agent.sh and in CHANGELOG.md; release tags are
  `vX.Y.Z`.
