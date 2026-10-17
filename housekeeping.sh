#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Cursor Cloud Housekeeping: Clean Up Chats, Chat History, and Environments
# Reference:
#   - v1 API: https://cursor.com/docs/cloud-agent/api/endpoints
#   - v0 API: https://cursor.com/docs/cloud-agent/api/v0
#
# Usage:
#   export CURSOR_API_KEY="your_api_key_here"
#   ./housekeeping.sh [SWITCHES] [OPTIONS]
# ==============================================================================

BASE_URL="${CURSOR_API_BASE_URL:-https://api.cursor.com}"
API_KEY="${CURSOR_API_KEY:-}"
CURL_TIMEOUT="${CURSOR_API_TIMEOUT:-30}"

CLEAN_ARCHIVED_CHATS=false
CLEAN_ACTIVE_CHATS=false
CLEAN_CHAT_HISTORY=false
CLEAN_ENVIRONMENTS=false
EXPORT_HISTORY=false
DRY_RUN=false
VERBOSE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
  echo "ERROR: Cannot create or write to log directory '${LOG_DIR}'. Check folder permissions." >&2
  exit 1
fi
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/housekeeping_${TIMESTAMP}.log}"

usage() {
  cat <<EOF
Usage: CURSOR_API_KEY=<key> $0 [TARGET SWITCHES] [OPTIONS]

Target Switches (select one or more):
  --all-agents, --agents         Delete all Cloud Agents (synonym for --all-chats)
  --archived-agents              Delete only archived Cloud Agents (synonym for --archived-chats)
  --active-agents                Delete only active/idle Cloud Agents (synonym for --active-chats)
  --all-chats, --chats           Delete both archived and active/idle Cloud Agent chats
  --archived-chats, --archived   Delete only archived Cloud Agent chats (status=ARCHIVED)
  --active-chats, --active       Delete only active/idle (non-archived) Cloud Agent chats
  --chat-history, --history      Inspect & purge chat run/conversation history (cancels active runs)
  --environments, --envs         Delete all saved Cloud Agent environments & their history
  -a, --all                      Clean up everything (all agents/chats, chat history, and environments)

Options:
  --export-history               Export conversation & run history JSON to logs/ before deleting
  -v, --verbose, --verbous       Show detailed metadata, run/chat history, and deletion progress
  -n, --dry-run                  Preview items to be cleaned up without deleting anything
  -h, --help                     Show this help message
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
      log_hint "Your API key does not have permission to modify this resource (e.g. team admin rights required)."
      ;;
    404)
      log_err "${context} failed with HTTP 404 (Not Found): ${detail}"
      log_hint "The resource may have already been deleted, or the ID/endpoint URL is invalid."
      ;;
    409)
      log_err "${context} failed with HTTP 409 (Conflict): ${detail}"
      log_hint "The resource has a conflicting state (e.g. an active run is busy or already terminated)."
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
if [[ $# -eq 0 ]]; then
  log_err "No target switches provided."
  log_hint "Pass at least one target switch: --archived-chats, --active-chats, --all-chats, --chat-history, --environments, or --all (use --help for usage)."
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --archived-chats|--archived|--archived-agents) CLEAN_ARCHIVED_CHATS=true ;;
    --active-chats|--active|--active-agents)       CLEAN_ACTIVE_CHATS=true ;;
    --all-chats|--chats|--all-agents|--agents)    CLEAN_ARCHIVED_CHATS=true; CLEAN_ACTIVE_CHATS=true ;;
    --chat-history|--history)                     CLEAN_CHAT_HISTORY=true ;;
    --environments|--envs)                        CLEAN_ENVIRONMENTS=true ;;
    --all|-a)
      CLEAN_ARCHIVED_CHATS=true
      CLEAN_ACTIVE_CHATS=true
      CLEAN_CHAT_HISTORY=true
      CLEAN_ENVIRONMENTS=true
      ;;
    --export-history)                             EXPORT_HISTORY=true ;;
    --verbose|--verbous|-v)                       VERBOSE=true ;;
    --dry-run|-n)                                 DRY_RUN=true ;;
    --help|-h)                                    usage; exit 0 ;;
    *)
      log_err "Unknown option or switch '${arg}'."
      log_hint "Valid switches: --all-agents, --archived-agents, --active-agents, --all-chats, --archived-chats, --active-chats, --chat-history, --environments, --all, --export-history, --verbose, --dry-run."
      exit 1
      ;;
  esac
done

# If --chat-history was passed without a specific chat filter (--archived-chats or --active-chats),
# apply chat history cleanup across all chats (archived + active).
if [[ "$CLEAN_CHAT_HISTORY" == "true" && "$CLEAN_ARCHIVED_CHATS" == "false" && "$CLEAN_ACTIVE_CHATS" == "false" ]]; then
  CLEAN_ARCHIVED_CHATS=true
  CLEAN_ACTIVE_CHATS=true
fi

if [[ "$CLEAN_ARCHIVED_CHATS" == "false" && "$CLEAN_ACTIVE_CHATS" == "false" && "$CLEAN_ENVIRONMENTS" == "false" && "$CLEAN_CHAT_HISTORY" == "false" ]]; then
  log_err "No cleanup target selected."
  log_hint "Specify at least one target switch: --archived-chats, --active-chats, --all-chats, --chat-history, --environments, or --all."
  exit 1
fi

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

vlog "Targets: archived_chats=${CLEAN_ARCHIVED_CHATS}, active_chats=${CLEAN_ACTIVE_CHATS}, chat_history=${CLEAN_CHAT_HISTORY}, environments=${CLEAN_ENVIRONMENTS}, export_history=${EXPORT_HISTORY}, dry_run=${DRY_RUN}"

CHATS_FOUND=0
CHATS_TARGETED=0
CHATS_DELETED=0
CHATS_FAILED=0
RUNS_CANCELLED=0
HISTORY_RUNS_TOTAL=0

ENVS_FOUND=0
ENVS_DELETED=0
ENVS_FAILED=0
ENV_HISTORY_EVENTS_TOTAL=0

# ==============================================================================
# Part 1: Chats (Agents) & Chat History Cleanup
# ==============================================================================
if [[ "$CLEAN_ARCHIVED_CHATS" == "true" || "$CLEAN_ACTIVE_CHATS" == "true" || "$CLEAN_CHAT_HISTORY" == "true" ]]; then
  log "Listing Cloud Agent chats..."

  ALL_CHATS_JSON="[]"
  CURSOR=""
  PAGE=1

  while true; do
    URL="${BASE_URL}/v1/agents?limit=100&includeArchived=true${CURSOR:+&cursor=$CURSOR}"
    vlog "Fetching chats page ${PAGE}: GET ${URL}"

    RESP_FILE=$(mktemp)
    CURL_EXIT=0
    HTTP_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$RESP_FILE" \
      --request GET --url "$URL" -u "${API_KEY}:") || CURL_EXIT=$?

    if [[ "$CURL_EXIT" -ne 0 ]]; then
      explain_curl_error "$CURL_EXIT" "$URL"
      rm -f "$RESP_FILE"
      exit 1
    fi

    if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
      explain_http_error "$HTTP_STATUS" "Listing Cloud Agent chats (GET /v1/agents)" "$RESP_FILE"
      rm -f "$RESP_FILE"
      exit 1
    fi

    if ! validate_json_file "$RESP_FILE" "Listing Cloud Agent chats (GET /v1/agents)"; then
      rm -f "$RESP_FILE"
      exit 1
    fi

    PAGE_ITEMS=$(jq -c '.items // []' "$RESP_FILE")
    NEXT_CURSOR=$(jq -r '.nextCursor // empty' "$RESP_FILE")
    rm -f "$RESP_FILE"

    ALL_CHATS_JSON=$(jq -c -n --argjson cur "$ALL_CHATS_JSON" --argjson page "$PAGE_ITEMS" '$cur + $page')
    [[ -z "$NEXT_CURSOR" ]] && break
    CURSOR="$NEXT_CURSOR"
    PAGE=$((PAGE + 1))
  done

  CHATS_FOUND=$(echo "$ALL_CHATS_JSON" | jq 'length')
  ARCHIVED_TOTAL=$(echo "$ALL_CHATS_JSON" | jq '[.[] | select(.status == "ARCHIVED")] | length')
  ACTIVE_TOTAL=$((CHATS_FOUND - ARCHIVED_TOTAL))

  TARGET_CHATS_JSON=$(echo "$ALL_CHATS_JSON" | jq -c \
    --arg archive "$CLEAN_ARCHIVED_CHATS" \
    --arg active "$CLEAN_ACTIVE_CHATS" '
    [ .[] | select(
      ($archive == "true" and .status == "ARCHIVED") or
      ($active == "true" and .status != "ARCHIVED")
    ) ]
  ')
  CHATS_TARGETED=$(echo "$TARGET_CHATS_JSON" | jq 'length')

  log "Chats found: ${CHATS_FOUND} (archived: ${ARCHIVED_TOTAL}, active/idle: ${ACTIVE_TOTAL}) | targeted: ${CHATS_TARGETED}"

  if [[ "$CHATS_TARGETED" -gt 0 ]]; then
    if [[ "$EXPORT_HISTORY" == "true" ]]; then
      HISTORY_EXPORT_DIR="${LOG_DIR}/chat_history_${TIMESTAMP}"
      mkdir -p "$HISTORY_EXPORT_DIR"
      log "Exporting chat history to ${HISTORY_EXPORT_DIR#$SCRIPT_DIR/}..."
    fi

    INDEX=0
    while IFS=$'\t' read -r id status archived latest_run created_at name; do
      INDEX=$((INDEX + 1))
      log "  - Chat ${id} | status=${status} | archived=${archived} | ${name}"
      vlog "    [${INDEX}/${CHATS_TARGETED}] createdAt=${created_at}, latestRunId=${latest_run}"

      if [[ "$VERBOSE" == "true" ]]; then
        DETAIL_FILE=$(mktemp)
        DETAIL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$DETAIL_FILE" \
          --request GET --url "${BASE_URL}/v1/agents/${id}" -u "${API_KEY}:") || DETAIL_STATUS="000"
        if [[ "$DETAIL_STATUS" -ge 200 && "$DETAIL_STATUS" -lt 300 ]] && jq -e . "$DETAIL_FILE" >/dev/null 2>&1; then
          REPOS_INFO=$(jq -r '(.repos // []) | map("\(.url) (ref: \(.startingRef // "default"))") | join(", ")' "$DETAIL_FILE")
          AUTO_PR=$(jq -r '.autoCreatePR // false' "$DETAIL_FILE")
          WORK_BRANCH=$(jq -r '.workOnCurrentBranch // false' "$DETAIL_FILE")
          vlog "      Repositories : ${REPOS_INFO:-none}"
          vlog "      Options      : autoCreatePR=${AUTO_PR}, workOnCurrentBranch=${WORK_BRANCH}"
        fi
        rm -f "$DETAIL_FILE"
      fi

      if [[ "$CLEAN_CHAT_HISTORY" == "true" || "$VERBOSE" == "true" || "$EXPORT_HISTORY" == "true" ]]; then
        RUNS_FILE=$(mktemp)
        RUNS_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$RUNS_FILE" \
          --request GET --url "${BASE_URL}/v1/agents/${id}/runs?limit=100" -u "${API_KEY}:") || RUNS_STATUS="000"

        if [[ "$RUNS_STATUS" -ge 200 && "$RUNS_STATUS" -lt 300 ]] && jq -e . "$RUNS_FILE" >/dev/null 2>&1; then
          RUN_COUNT=$(jq '.items // [] | length' "$RUNS_FILE")
          HISTORY_RUNS_TOTAL=$((HISTORY_RUNS_TOTAL + RUN_COUNT))
          vlog "    [${INDEX}/${CHATS_TARGETED}] Chat history has ${RUN_COUNT} run(s)"

          if [[ "$EXPORT_HISTORY" == "true" ]]; then
            cp "$RUNS_FILE" "${HISTORY_EXPORT_DIR}/${id}_runs.json"
          fi
        else
          vlog "    [${INDEX}/${CHATS_TARGETED}] Warning: Could not read run history for ${id} (HTTP ${RUNS_STATUS})"
        fi
        rm -f "$RUNS_FILE"

        if [[ "$EXPORT_HISTORY" == "true" || "$VERBOSE" == "true" ]]; then
          CONV_FILE=$(mktemp)
          CONV_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$CONV_FILE" \
            --request GET --url "${BASE_URL}/v0/agents/${id}/conversation" -u "${API_KEY}:") || CONV_STATUS="000"
          if [[ "$CONV_STATUS" -ge 200 && "$CONV_STATUS" -lt 300 ]] && jq -e . "$CONV_FILE" >/dev/null 2>&1; then
            MSG_COUNT=$(jq '.messages // [] | length' "$CONV_FILE" 2>/dev/null || echo 0)
            vlog "    [${INDEX}/${CHATS_TARGETED}] Conversation transcript messages: ${MSG_COUNT}"
            if [[ "$EXPORT_HISTORY" == "true" ]]; then
              cp "$CONV_FILE" "${HISTORY_EXPORT_DIR}/${id}_conversation.json"
            fi
          fi
          rm -f "$CONV_FILE"
        fi
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        vlog "    [${INDEX}/${CHATS_TARGETED}] Dry-run: would delete chat ${id} and its history"
        continue
      fi

      if [[ "$status" == "ACTIVE" && -n "$latest_run" && "$latest_run" != "none" ]]; then
        vlog "    [${INDEX}/${CHATS_TARGETED}] Cancelling active run ${latest_run} on chat ${id}..."
        CANCEL_FILE=$(mktemp)
        CANCEL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$CANCEL_FILE" \
          --request POST --url "${BASE_URL}/v1/agents/${id}/runs/${latest_run}/cancel" -u "${API_KEY}:") || CANCEL_STATUS="000"
        rm -f "$CANCEL_FILE"
        if [[ "$CANCEL_STATUS" -ge 200 && "$CANCEL_STATUS" -lt 300 ]]; then
          RUNS_CANCELLED=$((RUNS_CANCELLED + 1))
          vlog "    [${INDEX}/${CHATS_TARGETED}] Cancelled active run ${latest_run} (HTTP ${CANCEL_STATUS})"
        else
          vlog "    [${INDEX}/${CHATS_TARGETED}] Note: Run ${latest_run} cancel returned HTTP ${CANCEL_STATUS} (proceeding with delete)"
        fi
      fi

      DELETE_CHAT_URL="${BASE_URL}/v1/agents/${id}"
      DEL_FILE=$(mktemp)
      DEL_CURL_EXIT=0
      DEL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$DEL_FILE" \
        --request DELETE --url "$DELETE_CHAT_URL" -u "${API_KEY}:") || DEL_CURL_EXIT=$?

      if [[ "$DEL_CURL_EXIT" -ne 0 ]]; then
        CHATS_FAILED=$((CHATS_FAILED + 1))
        explain_curl_error "$DEL_CURL_EXIT" "$DELETE_CHAT_URL"
      elif [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
        CHATS_DELETED=$((CHATS_DELETED + 1))
        log "    Deleted chat ${id}"
        vlog "    [${INDEX}/${CHATS_TARGETED}] Confirmed DELETE /v1/agents/${id} (HTTP ${DEL_STATUS})"
      else
        CHATS_FAILED=$((CHATS_FAILED + 1))
        explain_http_error "$DEL_STATUS" "Deleting chat '${id}' (${name})" "$DEL_FILE"
      fi
      rm -f "$DEL_FILE"
    done < <(
      echo "$TARGET_CHATS_JSON" | jq -r '.[] | [
        .id,
        (.status // "UNKNOWN"),
        (if .status == "ARCHIVED" then "yes" else "no" end),
        (.latestRunId // "none"),
        (.createdAt // "-"),
        (.name // "(unnamed)")
      ] | @tsv'
    )
  fi
fi

# ==============================================================================
# Part 2: Cloud Agent Saved Environments & Environment History Cleanup
# ==============================================================================
if [[ "$CLEAN_ENVIRONMENTS" == "true" ]]; then
  log "Listing Cloud Agent environments..."

  ALL_ENVS_JSON="[]"
  CURSOR=""
  PAGE=1

  while true; do
    URL="${BASE_URL}/v1/environments?limit=100${CURSOR:+&cursor=$CURSOR}"
    vlog "Fetching environments page ${PAGE}: GET ${URL}"

    RESP_FILE=$(mktemp)
    CURL_EXIT=0
    HTTP_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$RESP_FILE" \
      --request GET --url "$URL" -u "${API_KEY}:") || CURL_EXIT=$?

    if [[ "$CURL_EXIT" -ne 0 ]]; then
      explain_curl_error "$CURL_EXIT" "$URL"
      rm -f "$RESP_FILE"
      exit 1
    fi

    if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
      explain_http_error "$HTTP_STATUS" "Listing Cloud Agent environments (GET /v1/environments)" "$RESP_FILE"
      rm -f "$RESP_FILE"
      exit 1
    fi

    if ! validate_json_file "$RESP_FILE" "Listing Cloud Agent environments (GET /v1/environments)"; then
      rm -f "$RESP_FILE"
      exit 1
    fi

    PAGE_ITEMS=$(jq -c '.items // []' "$RESP_FILE")
    NEXT_CURSOR=$(jq -r '.nextCursor // empty' "$RESP_FILE")
    rm -f "$RESP_FILE"

    ALL_ENVS_JSON=$(jq -c -n --argjson cur "$ALL_ENVS_JSON" --argjson page "$PAGE_ITEMS" '$cur + $page')
    [[ -z "$NEXT_CURSOR" ]] && break
    CURSOR="$NEXT_CURSOR"
    PAGE=$((PAGE + 1))
  done

  ENVS_FOUND=$(echo "$ALL_ENVS_JSON" | jq 'length')
  log "Found ${ENVS_FOUND} environment(s)"

  if [[ "$ENVS_FOUND" -gt 0 ]]; then
    INDEX=0
    while IFS=$'\t' read -r env_id owner repo_count updated_at env_name; do
      INDEX=$((INDEX + 1))
      log "  - Env ${env_id} | owner=${owner} | repos=${repo_count} | ${env_name}"
      vlog "    [${INDEX}/${ENVS_FOUND}] updatedAt=${updated_at}"

      if [[ "$VERBOSE" == "true" ]]; then
        HIST_FILE=$(mktemp)
        HIST_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$HIST_FILE" \
          --request GET --url "${BASE_URL}/v1/environments/${env_id}/history?limit=100" -u "${API_KEY}:") || HIST_STATUS="000"
        if [[ "$HIST_STATUS" -ge 200 && "$HIST_STATUS" -lt 300 ]] && jq -e . "$HIST_FILE" >/dev/null 2>&1; then
          HIST_COUNT=$(jq '.items // [] | length' "$HIST_FILE")
          ENV_HISTORY_EVENTS_TOTAL=$((ENV_HISTORY_EVENTS_TOTAL + HIST_COUNT))
          vlog "    [${INDEX}/${ENVS_FOUND}] Environment history events: ${HIST_COUNT}"
        fi
        rm -f "$HIST_FILE"
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        vlog "    [${INDEX}/${ENVS_FOUND}] Dry-run: would delete environment ${env_id} ('${env_name}')"
        continue
      fi

      DELETE_ENV_URL="${BASE_URL}/v1/environments/${env_id}"
      DEL_FILE=$(mktemp)
      DEL_CURL_EXIT=0
      DEL_STATUS=$(curl -sS --max-time "$CURL_TIMEOUT" -w "%{http_code}" -o "$DEL_FILE" \
        --request DELETE --url "$DELETE_ENV_URL" -u "${API_KEY}:") || DEL_CURL_EXIT=$?

      if [[ "$DEL_CURL_EXIT" -ne 0 ]]; then
        ENVS_FAILED=$((ENVS_FAILED + 1))
        explain_curl_error "$DEL_CURL_EXIT" "$DELETE_ENV_URL"
      elif [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
        ENVS_DELETED=$((ENVS_DELETED + 1))
        log "    Deleted environment ${env_id}"
        vlog "    [${INDEX}/${ENVS_FOUND}] Confirmed DELETE /v1/environments/${env_id} (HTTP ${DEL_STATUS})"
      else
        ENVS_FAILED=$((ENVS_FAILED + 1))
        explain_http_error "$DEL_STATUS" "Deleting environment '${env_id}' (${env_name})" "$DEL_FILE"
      fi
      rm -f "$DEL_FILE"
    done < <(
      echo "$ALL_ENVS_JSON" | jq -r '.[] | [
        .id,
        (.owner // "unknown"),
        ((.repos // []) | length | tostring),
        (.updatedAt // "-"),
        (.name // "(unnamed)")
      ] | @tsv'
    )
  fi
fi

# ==============================================================================
# Final Summary Log
# ==============================================================================
TOTAL_FAILED=$((CHATS_FAILED + ENVS_FAILED))
log "Done: chats_deleted=${CHATS_DELETED}/${CHATS_TARGETED} (runs_cancelled=${RUNS_CANCELLED}, history_runs=${HISTORY_RUNS_TOTAL}), envs_deleted=${ENVS_DELETED}/${ENVS_FOUND}, failed=${TOTAL_FAILED} | log=${LOG_FILE#$SCRIPT_DIR/}"

if [[ "$TOTAL_FAILED" -gt 0 ]]; then
  log_err "Housekeeping completed with ${TOTAL_FAILED} failure(s). Review error details and hints above."
  exit 1
fi
