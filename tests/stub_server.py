"""A stand-in for the QuickStatus.dev agent API, for the install tests.

    python3 tests/stub_server.py --port 18080 --log /tmp/requests.jsonl

Tokens: qse_good enrolls, qse_full answers 403 member_limit, anything else 401. Each request
is appended to the log as one JSON line; reports are gunzipped and, when the jsonschema
package is installed, checked against schema/payload.v1.json (failures answer 400).
"""

from __future__ import annotations

import argparse
import gzip
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "schema" / "payload.v1.json").read_text())
try:
    import jsonschema

    VALIDATOR = jsonschema.Draft202012Validator(SCHEMA)
except ImportError:  # pragma: no cover
    VALIDATOR = None

LOCK = threading.Lock()
MEMBERS: dict[str, str] = {}  # secret -> instance_key
BY_KEY: dict[str, str] = {}  # instance_key -> member id


class Handler(BaseHTTPRequestHandler):
    log_path: Path

    def log_message(self, *_args):  # quiet
        pass

    def _reply(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, entry: dict) -> None:
        with LOCK, self.log_path.open("a") as fh:
            fh.write(json.dumps(entry) + "\n")

    def do_POST(self):  # noqa: N802
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        bearer = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
        try:
            if (self.headers.get("Content-Encoding") or "").lower() == "gzip":
                raw = gzip.decompress(raw)
            body = json.loads(raw or b"{}")
        except Exception as exc:  # noqa: BLE001
            self._record({"path": self.path, "error": str(exc)})
            return self._reply(400, {"detail": "bad body"})
        entry = {"path": self.path, "bearer": bearer[:4], "ua": self.headers.get("User-Agent"),
                 "encoding": self.headers.get("Content-Encoding"), "body": body}

        if self.path == "/agent/enroll":
            if bearer == "qse_full":
                status, reply = 403, {"detail": "this check allows 1 server on the Free plan", "code": "member_limit"}
            elif bearer != "qse_good":
                status, reply = 401, {"detail": "unknown enrollment token", "code": "unknown_token"}
            else:
                key = body.get("instance_key") or ""
                secret = "qsm_" + secrets.token_urlsafe(16)
                with LOCK:
                    for old, k in list(MEMBERS.items()):
                        if k == key:
                            del MEMBERS[old]
                    MEMBERS[secret] = key
                    member_id = BY_KEY.setdefault(key, f"m-{len(BY_KEY) + 1}")
                status, reply = 200, {"member_id": member_id, "secret": secret, "interval_s": 60,
                                      "offset_s": 0, "latest_version": "0.1.0"}
        elif self.path == "/agent/report":
            if bearer not in MEMBERS:
                status, reply = 401, {"detail": "unknown member, enroll again", "code": "unknown_member"}
            else:
                errors = [e.message for e in VALIDATOR.iter_errors(body)] if VALIDATOR else []
                entry["schema_errors"] = errors
                status, reply = (400, {"detail": "; ".join(errors)}) if errors else (
                    200, {"stored": True, "interval_s": 60, "offset_s": 0, "latest_version": "0.2.0"})
        elif self.path == "/agent/leave":
            with LOCK:
                found = MEMBERS.pop(bearer, None)
            status, reply = (200, {"ok": True}) if found else (401, {"detail": "unknown member"})
        elif self.path == "/_revoke":
            # Test hook: forget every member secret (as if removed in the console).
            with LOCK:
                MEMBERS.clear()
            status, reply = 200, {"ok": True}
        else:
            status, reply = 404, {"detail": "not found"}
        entry["status"] = status
        self._record(entry)
        self._reply(status, reply)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    Handler.log_path = args.log
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
