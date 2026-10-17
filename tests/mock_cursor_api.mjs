#!/usr/bin/env node
/**
 * Mock Cursor Cloud Agents API server (Node.js zero-dependency)
 * Implements v1 and v0 endpoints plus simulated error conditions for testing
 * housekeeping.sh & delete_all_agents.sh
 */

import http from "node:http";
import { URL } from "node:url";

const INITIAL_AGENTS = [
  {
    id: "bc-00000000-0000-0000-0000-000000000001",
    name: "Fix authentication token refresh",
    status: "ACTIVE",
    env: { type: "cloud" },
    repos: [{ url: "https://github.com/acme/backend", startingRef: "main" }],
    workOnCurrentBranch: false,
    autoCreatePR: true,
    url: "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000001",
    createdAt: "2026-10-15T10:00:00.000Z",
    updatedAt: "2026-10-17T14:00:00.000Z",
    latestRunId: "run-00000000-0000-0000-0000-000000000101",
  },
  {
    id: "bc-00000000-0000-0000-0000-000000000002",
    name: "Refactor payment webhook handler",
    status: "IDLE",
    env: { type: "cloud" },
    repos: [{ url: "https://github.com/acme/payments", startingRef: "develop" }],
    workOnCurrentBranch: true,
    autoCreatePR: false,
    url: "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000002",
    createdAt: "2026-10-14T09:15:00.000Z",
    updatedAt: "2026-10-16T11:30:00.000Z",
    latestRunId: "run-00000000-0000-0000-0000-000000000102",
  },
  {
    id: "bc-00000000-0000-0000-0000-000000000003",
    name: "Add README setup instructions",
    status: "ARCHIVED",
    env: { type: "cloud" },
    repos: [{ url: "https://github.com/acme/docs", startingRef: "main" }],
    workOnCurrentBranch: false,
    autoCreatePR: true,
    url: "https://cursor.com/agents/bc-00000000-0000-0000-0000-000000000003",
    createdAt: "2026-10-01T08:00:00.000Z",
    updatedAt: "2026-10-02T12:00:00.000Z",
    latestRunId: "run-00000000-0000-0000-0000-000000000103",
  },
];

const INITIAL_ENVIRONMENTS = [
  {
    id: "env-8f14e45f-ceea-4e6b-9c3a-1d2e3f4a5b6c",
    name: "Production Web App",
    owner: "team",
    repos: [
      { url: "https://github.com/acme/backend" },
      { url: "https://github.com/acme/frontend" },
    ],
    createdAt: "2026-09-01T16:20:00.000Z",
    updatedAt: "2026-09-29T21:05:00.000Z",
  },
  {
    id: "env-2c91a11b-77d1-4a2b-8f10-9a8b7c6d5e4f",
    name: "Personal Sandbox",
    owner: "personal",
    repos: [{ url: "https://github.com/acme/payments" }],
    createdAt: "2026-10-05T12:00:00.000Z",
    updatedAt: "2026-10-10T15:45:00.000Z",
  },
];

let agents = structuredClone(INITIAL_AGENTS);
let environments = structuredClone(INITIAL_ENVIRONMENTS);

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function getApiKey(req) {
  const auth = req.headers["authorization"] || "";
  if (auth.startsWith("Basic ")) {
    const decoded = Buffer.from(auth.slice(6), "base64").toString("utf8");
    return decoded.split(":")[0];
  }
  return "";
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  const path = url.pathname;
  const method = req.method;
  const apiKey = getApiKey(req);

  if (method === "POST" && path === "/__reset") {
    agents = structuredClone(INITIAL_AGENTS);
    environments = structuredClone(INITIAL_ENVIRONMENTS);
    return sendJson(res, 200, { ok: true });
  }

  // Simulated global error modes triggered by test API keys
  if (apiKey === "invalid_key") {
    return sendJson(res, 401, {
      error: "unauthorized",
      message: "Invalid or expired Cursor API key",
    });
  }
  if (apiKey === "rate_limited_key") {
    return sendJson(res, 429, {
      error: "rate_limit_exceeded",
      message: "API rate limit of 60 requests/min exceeded",
    });
  }
  if (apiKey === "server_error_key") {
    return sendJson(res, 503, {
      error: "service_unavailable",
      message: "Upstream database is temporarily unavailable",
    });
  }
  if (apiKey === "bad_json_key") {
    const html = "<html><body><h1>502 Bad Gateway</h1></body></html>";
    res.writeHead(200, { "Content-Type": "text/html" });
    return res.end(html);
  }

  if (method === "GET" && path === "/v1/agents") {
    const includeArchived = (url.searchParams.get("includeArchived") ?? "true").toLowerCase() === "true";
    const items = agents.filter((a) => includeArchived || a.status !== "ARCHIVED");
    return sendJson(res, 200, { items });
  }

  let m = path.match(/^\/v1\/agents\/([^/]+)$/);
  if (m && method === "GET") {
    const agent = agents.find((a) => a.id === m[1]);
    return agent ? sendJson(res, 200, agent) : sendJson(res, 404, { error: "agent_not_found" });
  }
  if (m && method === "DELETE") {
    if (apiKey === "partial_delete_fail_key" && m[1] === "bc-00000000-0000-0000-0000-000000000002") {
      return sendJson(res, 403, {
        error: "forbidden",
        message: "Insufficient permissions to delete locked agent bc-00000000-0000-0000-0000-000000000002",
      });
    }
    const idx = agents.findIndex((a) => a.id === m[1]);
    if (idx !== -1) {
      agents.splice(idx, 1);
      return sendJson(res, 200, { id: m[1] });
    }
    return sendJson(res, 404, { error: "agent_not_found", message: `Agent ${m[1]} not found` });
  }

  m = path.match(/^\/v1\/agents\/([^/]+)\/runs$/);
  if (m && method === "GET") {
    const agentId = m[1];
    return sendJson(res, 200, {
      items: [
        {
          id: `run-for-${agentId}-1`,
          agentId,
          status: "FINISHED",
          createdAt: "2026-10-15T10:00:00.000Z",
          updatedAt: "2026-10-15T10:05:00.000Z",
        },
        {
          id: `run-for-${agentId}-2`,
          agentId,
          status: "RUNNING",
          createdAt: "2026-10-17T14:00:00.000Z",
          updatedAt: "2026-10-17T14:01:00.000Z",
        },
      ],
    });
  }

  m = path.match(/^\/v1\/agents\/([^/]+)\/runs\/([^/]+)\/cancel$/);
  if (m && method === "POST") {
    return sendJson(res, 200, { id: m[2] });
  }

  m = path.match(/^\/v0\/agents\/([^/]+)\/conversation$/);
  if (m && method === "GET") {
    return sendJson(res, 200, {
      id: m[1],
      messages: [
        { id: "msg-1", type: "user_message", text: "Please fix the issue" },
        { id: "msg-2", type: "assistant_message", text: "I have updated the module and added tests." },
      ],
    });
  }

  if (method === "GET" && path === "/v1/environments") {
    return sendJson(res, 200, { items: environments });
  }

  m = path.match(/^\/v1\/environments\/([^/]+)\/history$/);
  if (m && method === "GET") {
    return sendJson(res, 200, {
      items: [
        { id: `evt-${m[1]}-1`, kind: "created", createdAt: "2026-09-01T16:20:00.000Z" },
        { id: `evt-${m[1]}-2`, kind: "updated", createdAt: "2026-09-29T21:05:00.000Z" },
      ],
    });
  }

  m = path.match(/^\/v1\/environments\/([^/]+)$/);
  if (m && method === "DELETE") {
    if (apiKey === "partial_delete_fail_key" && m[1] === "env-8f14e45f-ceea-4e6b-9c3a-1d2e3f4a5b6c") {
      return sendJson(res, 403, {
        error: "forbidden",
        message: "Team admin role required to delete team environment Production Web App",
      });
    }
    const idx = environments.findIndex((e) => e.id === m[1]);
    if (idx !== -1) {
      environments.splice(idx, 1);
      return sendJson(res, 200, { id: m[1] });
    }
    return sendJson(res, 404, { error: "environment_not_found" });
  }

  return sendJson(res, 404, { error: "not_found", path });
});

const port = Number(process.argv[2] || 18080);
server.listen(port, "127.0.0.1", () => {
  console.log(`Mock Cursor API listening on http://127.0.0.1:${port}`);
});
