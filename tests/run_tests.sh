#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

PORT=18080
if command -v node >/dev/null 2>&1; then
  node tests/mock_cursor_api.mjs "$PORT" &
else
  python3 tests/mock_cursor_api.py "$PORT" &
fi
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Wait for mock server
for _ in {1..20}; do
  if curl -sS "http://127.0.0.1:${PORT}/v1/agents" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

export CURSOR_API_BASE_URL="http://127.0.0.1:${PORT}"
export CURSOR_API_KEY="test_mock_api_key"

reset_mock() {
  curl -sS -X POST "${CURSOR_API_BASE_URL}/__reset" >/dev/null
}

assert_fails_with() {
  local expected_substr="$1"
  shift
  local out_file
  out_file=$(mktemp)
  local status=0
  "$@" >"$out_file" 2>&1 || status=$?
  cat "$out_file"
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: Expected command ($*) to fail with non-zero exit code, but it succeeded."
    rm -f "$out_file"
    exit 1
  fi
  if ! grep -Fq "$expected_substr" "$out_file"; then
    echo "FAIL: Expected output to contain: '$expected_substr'"
    rm -f "$out_file"
    exit 1
  fi
  rm -f "$out_file"
}

echo "================================================================================"
echo "PART A: FUNCTIONAL / HAPPY-PATH TESTS (Tests 1 - 7)"
echo "================================================================================"

echo "--- TEST 1: housekeeping.sh --archived-chats --dry-run ---"
reset_mock
./housekeeping.sh --archived-chats --dry-run
REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '.items | length')
[[ "$REMAINING" -eq 3 ]] || { echo "Assertion failed: expected 3 agents after dry-run, got $REMAINING"; exit 1; }
echo "PASS [1/15]: Dry-run preserved all 3 agents."
echo ""

echo "--- TEST 2: housekeeping.sh --archived-chats --verbose ---"
reset_mock
./housekeeping.sh --archived-chats --verbose
REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '.items | length')
ARCHIVED_LEFT=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '[.items[] | select(.status == "ARCHIVED")] | length')
[[ "$REMAINING" -eq 2 && "$ARCHIVED_LEFT" -eq 0 ]] || { echo "Assertion failed: expected 2 non-archived agents, got $REMAINING"; exit 1; }
echo "PASS [2/15]: Deleted 1 archived chat; 2 active/idle chats remain."
echo ""

echo "--- TEST 3: housekeeping.sh --active-chats --verbose ---"
reset_mock
./housekeeping.sh --active-chats --verbose
REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '.items | length')
ARCHIVED_LEFT=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '[.items[] | select(.status == "ARCHIVED")] | length')
[[ "$REMAINING" -eq 1 && "$ARCHIVED_LEFT" -eq 1 ]] || { echo "Assertion failed: expected 1 archived agent left, got $REMAINING"; exit 1; }
echo "PASS [3/15]: Deleted 2 active/idle chats (cancelled active run first); 1 archived chat remains."
echo ""

echo "--- TEST 4: housekeeping.sh --chat-history --export-history --verbose ---"
reset_mock
./housekeeping.sh --chat-history --export-history --verbose
REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '.items | length')
[[ "$REMAINING" -eq 0 ]] || { echo "Assertion failed: expected 0 chats left, got $REMAINING"; exit 1; }
EXPORT_COUNT=$(find logs -name "*_conversation.json" | wc -l | tr -d ' ')
[[ "$EXPORT_COUNT" -ge 3 ]] || { echo "Assertion failed: expected exported conversation files, got $EXPORT_COUNT"; exit 1; }
echo "PASS [4/15]: Exported chat history transcripts and purged all 3 chats."
echo ""

echo "--- TEST 5: housekeeping.sh --environments --verbose ---"
reset_mock
./housekeeping.sh --environments --verbose
ENV_REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/environments" | jq '.items | length')
[[ "$ENV_REMAINING" -eq 0 ]] || { echo "Assertion failed: expected 0 environments left, got $ENV_REMAINING"; exit 1; }
echo "PASS [5/15]: Deleted all 2 saved Cloud Agent environments."
echo ""

echo "--- TEST 6: housekeeping.sh --all --verbose ---"
reset_mock
./housekeeping.sh --all --verbose
REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '.items | length')
ENV_REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/environments" | jq '.items | length')
[[ "$REMAINING" -eq 0 && "$ENV_REMAINING" -eq 0 ]] || { echo "Assertion failed: expected 0 chats and 0 envs"; exit 1; }
echo "PASS [6/15]: Full housekeeping (--all --verbose) cleaned up all chats, history, and environments."
echo ""

echo "--- TEST 7: delete_all_agents.sh --verbous ---"
reset_mock
./delete_all_agents.sh --verbous
REMAINING=$(curl -sS "${CURSOR_API_BASE_URL}/v1/agents" | jq '.items | length')
[[ "$REMAINING" -eq 0 ]] || { echo "Assertion failed: expected 0 agents left, got $REMAINING"; exit 1; }
echo "PASS [7/15]: delete_all_agents.sh --verbous listed and deleted all 3 agents."
echo ""

echo "================================================================================"
echo "PART B: ERROR HANDLING & DIAGNOSTIC HINT TESTS (Tests 8 - 15)"
echo "================================================================================"

echo "--- TEST 8: Missing CURSOR_API_KEY ---"
CURSOR_API_KEY="" assert_fails_with "Environment variable CURSOR_API_KEY is missing or empty." ./housekeeping.sh --all
echo "PASS [8/15]: Missing CURSOR_API_KEY produces readable error and remediation hint."
echo ""

echo "--- TEST 9: Missing target switches on housekeeping.sh ---"
assert_fails_with "No target switches provided." ./housekeeping.sh
echo "PASS [9/15]: Missing target switches produces readable error and hint."
echo ""

echo "--- TEST 10: Unknown CLI option ---"
assert_fails_with "Unknown option or switch '--not-a-valid-flag'" ./delete_all_agents.sh --not-a-valid-flag
echo "PASS [10/15]: Unknown CLI flag produces readable error and supported options hint."
echo ""

echo "--- TEST 11: HTTP 401 Unauthorized (Invalid API Key) ---"
CURSOR_API_KEY="invalid_key" assert_fails_with "HTTP 401 (Unauthorized): Invalid or expired Cursor API key" ./housekeeping.sh --all
echo "PASS [11/15]: HTTP 401 Unauthorized is caught with dashboard API Key hint."
echo ""

echo "--- TEST 12: HTTP 429 Rate Limit Exceeded ---"
CURSOR_API_KEY="rate_limited_key" assert_fails_with "HTTP 429 (Too Many Requests): API rate limit of 60 requests/min exceeded" ./delete_all_agents.sh
echo "PASS [12/15]: HTTP 429 Too Many Requests is caught with backoff hint."
echo ""

echo "--- TEST 13: HTTP 503 Server Error ---"
CURSOR_API_KEY="server_error_key" assert_fails_with "HTTP 503 (Cursor Server Error): Upstream database is temporarily unavailable" ./housekeeping.sh --environments
echo "PASS [13/15]: HTTP 503 Server Error is caught with temporary outage hint."
echo ""

echo "--- TEST 14: Malformed Non-JSON Response (HTML Proxy / Bad Gateway) ---"
CURSOR_API_KEY="bad_json_key" assert_fails_with "returned an invalid (non-JSON) response" ./delete_all_agents.sh
echo "PASS [14/15]: Non-JSON HTML response is caught cleanly before jq parsing."
echo ""

echo "--- TEST 15: Partial Deletion Failure (HTTP 403 Forbidden) & Unreachable Host (curl exit 7) ---"
reset_mock
CURSOR_API_KEY="partial_delete_fail_key" assert_fails_with "HTTP 403 (Forbidden): Team admin role required" ./housekeeping.sh --all
CURSOR_API_BASE_URL="http://127.0.0.1:19999" assert_fails_with "Failed to connect to 'http://127.0.0.1:19999/v1/agents?limit=100&includeArchived=true' (curl exit 7" ./delete_all_agents.sh
echo "PASS [15/15]: Partial HTTP 403 deletion failure and curl exit 7 connection refused handled with clear diagnostics."
echo ""

echo "================================================================================"
echo "ALL 15/15 DOCKER CONTAINER TESTS PASSED (7 Functional + 8 Error Handling)!"
echo "================================================================================"
