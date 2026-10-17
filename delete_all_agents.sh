#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Cursor Cloud Agents: List & Delete All Agents
# Reference: https://cursor.com/docs/cloud-agent/api/endpoints
#
# Usage:
#   export CURSOR_API_KEY="your_api_key_here"
#   ./delete_all_agents.sh [--verbose] [--dry-run]
# ==============================================================================

BASE_URL="${CURSOR_API_BASE_URL:-https://api.cursor.com}"
API_KEY="${CURSOR_API_KEY:-}"
DRY_RUN=false
VERBOSE=false
CURL_TIMEOUT="${CURSOR_API_TIMEOUT:-30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
  echo "ERROR: Cannot create or write to log directory '${LOG_DIR}'. Check folder permissions." >&2
  exit 1
fi
LOG_FILE="${LOG_FILE:-${LOG_DIR}/delete_agents_$(date +%Y%m%d_%H%M%S).log}"

usage() {
  cat <<EOF
Usage: CURSOR_API_KEY=<key> $0 [OPTIONS]

Lists all Cursor Cloud Agents (showing whether each is archived or not) and
permanently deletes them.

Options:
  -v, --verbose, --verbous   Show detailed agent metadata, API requests, and deletion progress
  -n, --dry-run              List agents without deleting them
  -h, --help                 Show this help message
EOF
}

log() {
  printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
}

log_err() {
  printf "[%s] ERROR: %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2
}

log_hint() {
  printf "[%s]   -> Hint: %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2
}

vlog() {
  if [[ "$VERBOSE" == "true" ]]; then
    printf "[%s] [VERBOSE] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
  fi
}

# ------------------------------------------------------------------------------
# Readable Error Formatting Helpers
# ------------------------------------------------------------------------------
explain_curl_error() {
  local code="$1"
  local url="$2"
  case "$code" in
    6)
      log_err "Could not resolve host for '${url}' (curl exit 6)."
      log_hint "Check your internet connection or verify CURSOR_API_BASE_URL (${BASE_URL})."
      ;;
    7)
      log_err "Failed to connect to '${url}' (curl exit 7: connection refused/unreachable)."
      log_hint "Ensure the API server at ${BASE_URL} is reachable and not blocked by a firewall."
      ;;
    28)
      log_err "Request to '${url}' timed out after ${CURL_TIMEOUT}s (curl exit 28)."
      log_hint "Check network latency or increase CURSOR_API_TIMEOUT."
      ;;
    35|60)
      log_err "TLS/SSL handshake failed when connecting to '${url}' (curl exit ${code})."
      log_hint "Verify system CA certificates and system clock, or check proxy/VPN settings."
      ;;
    *)
      log_err "Network request to '${url}' failed (curl exit ${code})."
      log_hint "Verify network connectivity and CURSOR_API_BASE_URL (${BASE_URL})."
      ;;
  esac
}

extract_api_error_detail() {
  local body_file="$1"
  if [[ ! -s "$body_file" ]]; then
    echo "empty response body"
    return
  fi
  if jq -e . "$body_file" >/dev/null 2>&1; then
    local detail
    detail=$(jq -r '(.message // .error.message // .error // .code // empty)' "$body_file" 2>/dev/null || true)
    if [[ -n "$detail" && "$detail" != "null" ]]; then
      echo "$detail"
      return
    fi
  fi
  head -c 200 "$body_file" | tr '\n' ' '
}

explain_http_error() {
  local status="$1"
  local context="$2"
  local body_file="$3"
  local detail
  detail="$(extract_api_error_detail "$body_file")"

  case "$status" in
    400)
      log_err "${context} failed with HTTP 400 (Bad Request): ${detail}"
      log_hint "Check request parameters or pagination cursor format."
      ;;
    401)
      log_err "${context} failed with HTTP 401 (Unauthorized): ${detail}"
      log_hint "Your CURSOR_API_KEY is invalid, expired, or revoked. Generate a valid key at https://cursor.com/dashboard (API Keys)."
      ;;
    403)
      log_err "${context} failed with HTTP 403 (Forbidden): ${detail}"
      log_hint "Your API key does not have permission to access or delete this resource."
      ;;
    404)
      log_err "${context} failed with HTTP 404 (Not Found): ${detail}"
      log_hint "The agent may have already been deleted, or the endpoint URL is invalid."
      ;;
    409)
      log_err "${context} failed with HTTP 409 (Conflict): ${detail}"
      log_hint "The agent has a conflicting state (e.g. an active run is busy or cannot be cancelled)."
      ;;
    429)
      log_err "${context} failed with HTTP 429 (Too Many Requests): ${detail}"
      log_hint "Cursor API rate limit reached. Wait 30-60 seconds before re-running the script."
      ;;
    500|502|503|504)
      log_err "${context} failed with HTTP ${status} (Cursor Server Error): ${detail}"
      log_hint "Cursor Cloud API is experiencing a temporary outage. Retry shortly."
      ;;
    *)
      log_err "${context} failed with HTTP ${status}: ${detail}"
      log_hint "Inspect the log file (${LOG_FILE#$SCRIPT_DIR/}) or run with --verbose for details."
      ;;
  esac
}

validate_json_file() {
  local file="$1"
  local context="$2"
  if [[ ! -s "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
    local snippet
    snippet=$(head -c 200 "$file" 2>/dev/null | tr '\n' ' ' || true)
    log_err "${context} returned an invalid (non-JSON) response: ${snippet:-<empty>}"
    log_hint "Verify CURSOR_API_BASE_URL (${BASE_URL}) points to the Cursor API and not an HTML proxy/login page."
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Argument Parsing & Pre-flight Validation
# ------------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --verbose|--verbous|-v) VERBOSE=true ;;
    --dry-run|-n)           DRY_RUN=true ;;
    --help|-h)              usage; exit 0 ;;
    *)
      log_err "Unknown option '${arg}'."
      log_hint "Supported options are: --verbose (-v), --dry-run (-n), --help (-h)."
      exit 1
      ;;
  esac
done

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_err "Required CLI tool '${cmd}' is not installed or not in PATH."
    log_hint "Install it via Homebrew ('brew install ${cmd}') or apt ('sudo apt-get install -y ${cmd}')."
    exit 1
  fi
done

if [[ -z "${API_KEY// /}" ]]; then
  log_err "Environment variable CURSOR_API_KEY is missing or empty."
  log_hint "Create an API key at https://cursor.com/dashboard -> API Keys, then run: export CURSOR_API_KEY='your_key'"
  exit 1
fi

vlog "Initialized with BASE_URL=${BASE_URL}, DRY_RUN=${DRY_RUN}, LOG_FILE=${LOG_FILE#$SCRIPT_DIR/}"

# ------------------------------------------------------------------------------
# Step 1: List all Cloud Agents
# ------------------------------------------------------------------------------
log "Step 1/2: Listing agents..."

ALL_AGENTS_JSON="[]"
CURSOR=""
PAGE=1

while true; do
  URL="${BASE_URL}/v1/agents?limit=100&includeArchived=true${CURSOR:+&cursor=$CURSOR}"
  vlog "Requesting page ${PAGE}: GET ${URL}"

  RESPONSE_FILE=$(mktemp)
  CURL_EXIT=0
  HTTP_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$RESPONSE_FILE" \
    --request GET --url "$URL" -u "${API_KEY}:") || CURL_EXIT=$?

  if [[ "$CURL_EXIT" -ne 0 ]]; then
    explain_curl_error "$CURL_EXIT" "$URL"
    rm -f "$RESPONSE_FILE"
    exit 1
  fi

  if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
    explain_http_error "$HTTP_STATUS" "Listing Cloud Agents (GET /v1/agents)" "$RESPONSE_FILE"
    rm -f "$RESPONSE_FILE"
    exit 1
  fi

  if ! validate_json_file "$RESPONSE_FILE" "Listing Cloud Agents (GET /v1/agents)"; then
    rm -f "$RESPONSE_FILE"
    exit 1
  fi

  PAGE_ITEMS=$(jq -c '.items // []' "$RESPONSE_FILE")
  PAGE_COUNT=$(echo "$PAGE_ITEMS" | jq 'length')
  NEXT_CURSOR=$(jq -r '.nextCursor // empty' "$RESPONSE_FILE")
  rm -f "$RESPONSE_FILE"

  vlog "Page ${PAGE} returned ${PAGE_COUNT} agent(s) (HTTP ${HTTP_STATUS})${NEXT_CURSOR:+, nextCursor=${NEXT_CURSOR}}"

  ALL_AGENTS_JSON=$(jq -c -n --argjson cur "$ALL_AGENTS_JSON" --argjson page "$PAGE_ITEMS" '$cur + $page')
  [[ -z "$NEXT_CURSOR" ]] && break
  CURSOR="$NEXT_CURSOR"
  PAGE=$((PAGE + 1))
done

TOTAL=$(echo "$ALL_AGENTS_JSON" | jq 'length')
ARCHIVED=$(echo "$ALL_AGENTS_JSON" | jq '[.[] | select(.status == "ARCHIVED")] | length')
ACTIVE_COUNT=$(echo "$ALL_AGENTS_JSON" | jq '[.[] | select(.status == "ACTIVE")] | length')
IDLE_COUNT=$(echo "$ALL_AGENTS_JSON" | jq '[.[] | select(.status == "IDLE")] | length')
NON_ARCHIVED=$((TOTAL - ARCHIVED))

log "Found ${TOTAL} agent(s) (archived: ${ARCHIVED}, non-archived: ${NON_ARCHIVED})"
vlog "Status breakdown: ACTIVE=${ACTIVE_COUNT}, IDLE=${IDLE_COUNT}, ARCHIVED=${ARCHIVED}"

if [[ "$TOTAL" -gt 0 ]]; then
  INDEX=0
  while IFS=$'\t' read -r id status archived env_type created_at updated_at latest_run url name; do
    INDEX=$((INDEX + 1))
    log "  - ${id} | status=${status} | archived=${archived} | ${name}"

    if [[ "$VERBOSE" == "true" ]]; then
      vlog "    [${INDEX}/${TOTAL}] Details for ${id}:"
      vlog "      Name         : ${name}"
      vlog "      Status       : ${status} (Archived: ${archived})"
      vlog "      Environment  : ${env_type}"
      vlog "      Created At   : ${created_at}"
      vlog "      Updated At   : ${updated_at}"
      vlog "      Latest Run   : ${latest_run}"
      vlog "      Dashboard URL: ${url}"

      DETAIL_FILE=$(mktemp)
      DETAIL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$DETAIL_FILE" \
        --request GET --url "${BASE_URL}/v1/agents/${id}" -u "${API_KEY}:") || DETAIL_STATUS="000"
      if [[ "$DETAIL_STATUS" -ge 200 && "$DETAIL_STATUS" -lt 300 ]] && jq -e . "$DETAIL_FILE" >/dev/null 2>&1; then
        REPOS_INFO=$(jq -r '(.repos // []) | map("\(.url) (ref: \(.startingRef // "default"))") | join(", ")' "$DETAIL_FILE")
        AUTO_PR=$(jq -r '.autoCreatePR // false' "$DETAIL_FILE")
        WORK_BRANCH=$(jq -r '.workOnCurrentBranch // false' "$DETAIL_FILE")
        vlog "      Repositories : ${REPOS_INFO:-none}"
        vlog "      Options      : autoCreatePR=${AUTO_PR}, workOnCurrentBranch=${WORK_BRANCH}"
      else
        vlog "      Warning      : Could not fetch extended metadata for ${id} (HTTP ${DETAIL_STATUS})"
      fi
      rm -f "$DETAIL_FILE"
    fi
  done < <(
    echo "$ALL_AGENTS_JSON" | jq -r '.[] | [
      .id,
      (.status // "UNKNOWN"),
      (if .status == "ARCHIVED" then "yes" else "no" end),
      (.env.type // "unknown"),
      (.createdAt // "-"),
      (.updatedAt // "-"),
      (.latestRunId // "none"),
      (.url // "-"),
      (.name // "(unnamed)")
    ] | @tsv'
  )
fi

# ------------------------------------------------------------------------------
# Step 2: Delete all Cloud Agents
# ------------------------------------------------------------------------------
DELETED=0
FAILED=0

if [[ "$TOTAL" -eq 0 ]]; then
  log "Step 2/2: No agents to delete."
elif [[ "$DRY_RUN" == "true" ]]; then
  log "Step 2/2: Dry-run enabled, skipped deleting ${TOTAL} agent(s)."
else
  log "Step 2/2: Deleting ${TOTAL} agent(s)..."
  INDEX=0
  while IFS=$'\t' read -r id status archived latest_run name; do
    INDEX=$((INDEX + 1))
    DELETE_URL="${BASE_URL}/v1/agents/${id}"
    vlog "[${INDEX}/${TOTAL}] Preparing to delete agent ${id} ('${name}', status=${status}, archived=${archived})"

    if [[ "$status" == "ACTIVE" && -n "$latest_run" && "$latest_run" != "none" ]]; then
      vlog "[${INDEX}/${TOTAL}] Agent ${id} is ACTIVE (run ${latest_run}); attempting run cancellation before delete..."
      CANCEL_RESP=$(mktemp)
      CANCEL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$CANCEL_RESP" \
        --request POST --url "${BASE_URL}/v1/agents/${id}/runs/${latest_run}/cancel" -u "${API_KEY}:") || CANCEL_STATUS="000"
      vlog "[${INDEX}/${TOTAL}] Cancel run ${latest_run} returned HTTP ${CANCEL_STATUS}"
      rm -f "$CANCEL_RESP"
    fi

    vlog "[${INDEX}/${TOTAL}] Sending DELETE ${DELETE_URL}"
    DEL_RESP=$(mktemp)
    DEL_CURL_EXIT=0
    DEL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$DEL_RESP" \
      --request DELETE --url "$DELETE_URL" -u "${API_KEY}:") || DEL_CURL_EXIT=$?

    if [[ "$DEL_CURL_EXIT" -ne 0 ]]; then
      FAILED=$((FAILED + 1))
      explain_curl_error "$DEL_CURL_EXIT" "$DELETE_URL"
    elif [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
      DELETED=$((DELETED + 1))
      DEL_BODY=$(cat "$DEL_RESP" 2>/dev/null || true)
      log "  - Deleted ${id}"
      vlog "[${INDEX}/${TOTAL}] Confirmed permanent deletion of ${id} ('${name}') — HTTP ${DEL_STATUS}, response=${DEL_BODY}"
    else
      FAILED=$((FAILED + 1))
      explain_http_error "$DEL_STATUS" "Deleting agent '${id}' (${name})" "$DEL_RESP"
    fi
    rm -f "$DEL_RESP"
  done < <(
    echo "$ALL_AGENTS_JSON" | jq -r '.[] | [
      .id,
      (.status // "UNKNOWN"),
      (if .status == "ARCHIVED" then "yes" else "no" end),
      (.latestRunId // "none"),
      (.name // "(unnamed)")
    ] | @tsv'
  )
fi

# ------------------------------------------------------------------------------
# Final Log
# ------------------------------------------------------------------------------
log "Done: total=${TOTAL} (archived=${ARCHIVED}, non_archived=${NON_ARCHIVED}), deleted=${DELETED}, failed=${FAILED} | log=${LOG_FILE#$SCRIPT_DIR/}"

if [[ "$FAILED" -gt 0 ]]; then
  log_err "${FAILED} agent(s) could not be deleted. Review messages above or inspect ${LOG_FILE#$SCRIPT_DIR/}."
  exit 1
fi
