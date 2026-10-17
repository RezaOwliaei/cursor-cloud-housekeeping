#!/usr/bin/env python3
"""Mock Cursor Cloud Agents API server for testing housekeeping.sh and delete_all_agents.sh."""

import base64
import copy
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

INITIAL_AGENTS = [
    {
        "id": "bc-00000000-0000-0000-0000-000000000001",
        "name": "Fix authentication token refresh",
        "status": "ACTIVE",
        "env": {"type": "cloud"},
        "repos": [{"url": "https://github.com/acme/backend", "startingRef": "main"}],
        "workOnCurrentBranch": False,
        "autoCreatePR": True,
        "url": "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000001",
        "createdAt": "2026-10-15T10:00:00.000Z",
        "updatedAt": "2026-10-17T14:00:00.000Z",
        "latestRunId": "run-00000000-0000-0000-0000-000000000101",
    },
    {
        "id": "bc-00000000-0000-0000-0000-000000000002",
        "name": "Refactor payment webhook handler",
        "status": "IDLE",
        "env": {"type": "cloud"},
        "repos": [{"url": "https://github.com/acme/payments", "startingRef": "develop"}],
        "workOnCurrentBranch": True,
        "autoCreatePR": False,
        "url": "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000002",
        "createdAt": "2026-10-14T09:15:00.000Z",
        "updatedAt": "2026-10-16T11:30:00.000Z",
        "latestRunId": "run-00000000-0000-0000-0000-000000000102",
    },
    {
        "id": "bc-00000000-0000-0000-0000-000000000003",
        "name": "Add README setup instructions",
        "status": "ARCHIVED",
        "env": {"type": "cloud"},
        "repos": [{"url": "https://github.com/acme/docs", "startingRef": "main"}],
        "workOnCurrentBranch": False,
        "autoCreatePR": True,
        "url": "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000003",
        "createdAt": "2026-10-01T08:00:00.000Z",
        "updatedAt": "2026-10-02T12:00:00.000Z",
        "latestRunId": "run-00000000-0000-0000-0000-000000000103",
    },
]

INITIAL_ENVIRONMENTS = [
    {
        "id": "env-8f14e45f-ceea-4e6b-9c3a-1d2e3f4a5b6c",
        "name": "Production Web App",
        "owner": "team",
        "repos": [
            {"url": "https://github.com/acme/backend"},
            {"url": "https://github.com/acme/frontend"},
        ],
        "createdAt": "2026-09-01T16:20:00.000Z",
        "updatedAt": "2026-09-29T21:05:00.000Z",
    },
    {
        "id": "env-2c91a11b-77d1-4a2b-8f10-9a8b7c6d5e4f",
        "name": "Personal Sandbox",
        "owner": "personal",
        "repos": [{"url": "https://github.com/acme/payments"}],
        "createdAt": "2026-10-05T12:00:00.000Z",
        "updatedAt": "2026-10-10T15:45:00.000Z",
    },
]

STATE = {
    "agents": copy.deepcopy(INITIAL_AGENTS),
    "environments": copy.deepcopy(INITIAL_ENVIRONMENTS),
}


def reset_state():
    STATE["agents"] = copy.deepcopy(INITIAL_AGENTS)
    STATE["environments"] = copy.deepcopy(INITIAL_ENVIRONMENTS)


class MockCursorHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _get_api_key(self):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            decoded = base64.b64decode(auth[6:]).decode("utf-8", errors="ignore")
            return decoded.split(":", 1)[0]
        return ""

    def _check_error_modes(self):
        key = self._get_api_key()
        if key == "invalid_key":
            self._send_json(401, {"error": "unauthorized", "message": "Invalid or expired Cursor API key"})
            return True
        if key == "rate_limited_key":
            self._send_json(429, {"error": "rate_limit_exceeded", "message": "API rate limit of 60 requests/min exceeded"})
            return True
        if key == "server_error_key":
            self._send_json(503, {"error": "service_unavailable", "message": "Upstream database is temporarily unavailable"})
            return True
        if key == "bad_json_key":
            body = b"<html><body><h1>502 Bad Gateway</h1></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return True
        return False

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self._check_error_modes():
            return
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/v1/agents":
            include_archived = qs.get("includeArchived", ["true"])[0].lower() == "true"
            items = [
                a for a in STATE["agents"]
                if include_archived or a["status"] != "ARCHIVED"
            ]
            self._send_json(200, {"items": items})
            return

        m = re.match(r"^/v1/agents/([^/]+)$", path)
        if m:
            agent_id = m.group(1)
            for a in STATE["agents"]:
                if a["id"] == agent_id:
                    self._send_json(200, a)
                    return
            self._send_json(404, {"error": "agent_not_found"})
            return

        m = re.match(r"^/v1/agents/([^/]+)/runs$", path)
        if m:
            agent_id = m.group(1)
            self._send_json(
                200,
                {
                    "items": [
                        {
                            "id": f"run-for-{agent_id}-1",
                            "agentId": agent_id,
                            "status": "FINISHED",
                            "createdAt": "2026-10-15T10:00:00.000Z",
                            "updatedAt": "2026-10-15T10:05:00.000Z",
                        },
                        {
                            "id": f"run-for-{agent_id}-2",
                            "agentId": agent_id,
                            "status": "RUNNING",
                            "createdAt": "2026-10-17T14:00:00.000Z",
                            "updatedAt": "2026-10-17T14:01:00.000Z",
                        },
                    ]
                },
            )
            return

        m = re.match(r"^/v0/agents/([^/]+)/conversation$", path)
        if m:
            agent_id = m.group(1)
            self._send_json(
                200,
                {
                    "id": agent_id,
                    "messages": [
                        {"id": "msg-1", "type": "user_message", "text": "Please fix the issue"},
                        {"id": "msg-2", "type": "assistant_message", "text": "I have updated the module and added tests."},
                    ],
                },
            )
            return

        if path == "/v1/environments":
            self._send_json(200, {"items": STATE["environments"]})
            return

        m = re.match(r"^/v1/environments/([^/]+)/history$", path)
        if m:
            env_id = m.group(1)
            self._send_json(
                200,
                {
                    "items": [
                        {"id": f"evt-{env_id}-1", "kind": "created", "createdAt": "2026-09-01T16:20:00.000Z"},
                        {"id": f"evt-{env_id}-2", "kind": "updated", "createdAt": "2026-09-29T21:05:00.000Z"},
                    ]
                },
            )
            return

        self._send_json(404, {"error": "not_found", "path": path})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/__reset":
            reset_state()
            self._send_json(200, {"ok": True})
            return

        if self._check_error_modes():
            return

        m = re.match(r"^/v1/agents/([^/]+)/runs/([^/]+)/cancel$", path)
        if m:
            run_id = m.group(2)
            self._send_json(200, {"id": run_id})
            return

        self._send_json(404, {"error": "not_found", "path": path})

    def do_DELETE(self):
        if self._check_error_modes():
            return
        parsed = urlparse(self.path)
        path = parsed.path
        key = self._get_api_key()

        m = re.match(r"^/v1/agents/([^/]+)$", path)
        if m:
            agent_id = m.group(1)
            if key == "partial_delete_fail_key" and agent_id == "bc-00000000-0000-0000-0000-000000000002":
                self._send_json(
                    403,
                    {
                        "error": "forbidden",
                        "message": "Insufficient permissions to delete locked agent bc-00000000-0000-0000-0000-000000000002",
                    },
                )
                return
            before = len(STATE["agents"])
            STATE["agents"] = [a for a in STATE["agents"] if a["id"] != agent_id]
            if len(STATE["agents"]) < before:
                self._send_json(200, {"id": agent_id})
            else:
                self._send_json(404, {"error": "agent_not_found"})
            return

        m = re.match(r"^/v1/environments/([^/]+)$", path)
        if m:
            env_id = m.group(1)
            if key == "partial_delete_fail_key" and env_id == "env-8f14e45f-ceea-4e6b-9c3a-1d2e3f4a5b6c":
                self._send_json(
                    403,
                    {
                        "error": "forbidden",
                        "message": "Team admin role required to delete team environment Production Web App",
                    },
                )
                return
            before = len(STATE["environments"])
            STATE["environments"] = [e for e in STATE["environments"] if e["id"] != env_id]
            if len(STATE["environments"]) < before:
                self._send_json(200, {"id": env_id})
            else:
                self._send_json(404, {"error": "environment_not_found"})
            return

        self._send_json(404, {"error": "not_found", "path": path})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    server = HTTPServer(("127.0.0.1", port), MockCursorHandler)
    print(f"Mock Cursor API listening on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()
