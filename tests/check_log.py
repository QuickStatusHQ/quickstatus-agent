"""Checks the stub's request log after one container run."""

import json
import sys

entries = [json.loads(line) for line in open(sys.argv[1])]
reports = [e for e in entries if e["path"] == "/agent/report" and e["status"] == 200]
problems = []
if any(e.get("schema_errors") for e in entries):
    problems.append(f"schema errors: {[e['schema_errors'] for e in entries if e.get('schema_errors')]}")
if len(reports) < 3:
    problems.append(f"expected at least 3 accepted reports, got {len(reports)}")
else:
    first, second = reports[0]["body"], reports[1]["body"]
    if not all(r["encoding"] == "gzip" and r["ua"].startswith("quickstatus-agent/") for r in reports):
        problems.append("reports must be gzip with the agent User-Agent")
    if first["cpu"]["pct"] is not None:
        problems.append("first report can't have CPU % (no previous sample)")
    if second["cpu"]["pct"] is None or second["interval_s"] is None:
        problems.append(f"second report lacks cpu.pct/interval_s: {second['cpu']}")
    if not second["disks"] or second["disks"][0]["mount"] != "/":
        problems.append(f"disks: {second['disks']}")
    if second["mem"]["pct"] is None or not second["mem"]["total_bytes"]:
        problems.append(f"mem: {second['mem']}")
    watched = {w["name"]: w for w in second["procs"]["watched"]}
    if not watched.get("sh", {}).get("running"):
        problems.append(f"watched sh should be running: {watched}")
enrolls = [e for e in entries if e["path"] == "/agent/enroll" and e["status"] == 200]
if not enrolls or enrolls[0]["body"]["labels"].get("env") != "test":
    problems.append(f"enroll labels: {enrolls[:1]}")
if not any(e["path"] == "/agent/leave" and e["status"] == 200 for e in entries):
    problems.append("uninstall didn't send leave")
if problems:
    print("LOG CHECK FAILED:\n  " + "\n  ".join(problems))
    sys.exit(1)
print(f"log ok: {len(reports)} reports, {len(enrolls)} enrolls")
print(json.dumps(second, indent=1)[:1500])
