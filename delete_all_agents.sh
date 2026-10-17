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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
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

for arg in "$@"; do
  case "$arg" in
    --verbose|--verbous|-v) VERBOSE=true ;;
    --dry-run|-n)           DRY_RUN=true ;;
    --help|-h)              usage; exit 0 ;;
    *)
      echo "Unknown argument: $arg (use --help)" >&2
      exit 1
      ;;
  esac
done

log() {
  printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
}

vlog() {
  if [[ "$VERBOSE" == "true" ]]; then
    printf "[%s] [VERBOSE] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
  fi
}

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: '$cmd' is required."; exit 1; }
done

if [[ -z "$API_KEY" ]]; then
  log "ERROR: CURSOR_API_KEY is not set."
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
  HTTP_STATUS=$(curl -sS -w "%{http_code}" -o "$RESPONSE_FILE" \
    --request GET --url "$URL" -u "${API_KEY}:") || {
      log "ERROR: Network failure on GET /v1/agents"
      rm -f "$RESPONSE_FILE"
      exit 1
    }

  if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
    log "ERROR: GET /v1/agents failed (HTTP $HTTP_STATUS): $(cat "$RESPONSE_FILE")"
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

      # Fetch full agent record in verbose mode to show repository & branch settings
      DETAIL_FILE=$(mktemp)
      DETAIL_STATUS=$(curl -sS -w "%{http_code}" -o "$DETAIL_FILE" \
        --request GET --url "${BASE_URL}/v1/agents/${id}" -u "${API_KEY}:") || DETAIL_STATUS="000"
      if [[ "$DETAIL_STATUS" -ge 200 && "$DETAIL_STATUS" -lt 300 ]]; then
        REPOS_INFO=$(jq -r '(.repos // []) | map("\(.url) (ref: \(.startingRef // "default"))") | join(", ")' "$DETAIL_FILE")
        AUTO_PR=$(jq -r '.autoCreatePR // false' "$DETAIL_FILE")
        WORK_BRANCH=$(jq -r '.workOnCurrentBranch // false' "$DETAIL_FILE")
        vlog "      Repositories : ${REPOS_INFO:-none}"
        vlog "      Options      : autoCreatePR=${AUTO_PR}, workOnCurrentBranch=${WORK_BRANCH}"
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

    # If the agent is currently ACTIVE and has a run in progress, log & attempt to cancel first in verbose mode
    if [[ "$status" == "ACTIVE" && -n "$latest_run" && "$latest_run" != "none" ]]; then
      vlog "[${INDEX}/${TOTAL}] Agent ${id} is ACTIVE (run ${latest_run}); attempting run cancellation before delete..."
      CANCEL_RESP=$(mktemp)
      CANCEL_STATUS=$(curl -sS -w "%{http_code}" -o "$CANCEL_RESP" \
        --request POST --url "${BASE_URL}/v1/agents/${id}/runs/${latest_run}/cancel" -u "${API_KEY}:") || CANCEL_STATUS="000"
      vlog "[${INDEX}/${TOTAL}] Cancel run ${latest_run} returned HTTP ${CANCEL_STATUS}"
      rm -f "$CANCEL_RESP"
    fi

    vlog "[${INDEX}/${TOTAL}] Sending DELETE ${DELETE_URL}"
    DEL_RESP=$(mktemp)
    DEL_STATUS=$(curl -sS -w "%{http_code}" -o "$DEL_RESP" \
      --request DELETE --url "$DELETE_URL" -u "${API_KEY}:") || DEL_STATUS="000"
    DEL_BODY=$(cat "$DEL_RESP" 2>/dev/null || true)
    rm -f "$DEL_RESP"

    if [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
      DELETED=$((DELETED + 1))
      log "  - Deleted ${id}"
      vlog "[${INDEX}/${TOTAL}] Confirmed permanent deletion of ${id} ('${name}') — HTTP ${DEL_STATUS}, response=${DEL_BODY}"
    else
      FAILED=$((FAILED + 1))
      log "  - FAILED ${id} (HTTP ${DEL_STATUS}): ${DEL_BODY}"
    fi
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

[[ "$FAILED" -eq 0 ]]
