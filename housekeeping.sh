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

CLEAN_ARCHIVED_CHATS=false
CLEAN_ACTIVE_CHATS=false
CLEAN_CHAT_HISTORY=false
CLEAN_ENVIRONMENTS=false
EXPORT_HISTORY=false
DRY_RUN=false
VERBOSE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/housekeeping_${TIMESTAMP}.log}"

usage() {
  cat <<EOF
Usage: CURSOR_API_KEY=<key> $0 [TARGET SWITCHES] [OPTIONS]

Target Switches (select one or more):
  --archived-chats, --archived   Delete only archived Cloud Agent chats (status=ARCHIVED)
  --active-chats, --active       Delete only active/idle (non-archived) Cloud Agent chats
  --all-chats, --chats           Delete both archived and active/idle Cloud Agent chats
  --chat-history, --history      Inspect & purge chat run/conversation history (cancels active runs)
  --environments, --envs         Delete all saved Cloud Agent environments & their history
  -a, --all                      Clean up everything (all chats, chat history, and environments)

Options:
  --export-history               Export conversation & run history JSON to logs/ before deleting
  -v, --verbose, --verbous       Show detailed metadata, run/chat history, and deletion progress
  -n, --dry-run                  Preview items to be cleaned up without deleting anything
  -h, --help                     Show this help message

Examples:
  # Delete only archived chats (dry-run preview):
  ./housekeeping.sh --archived-chats --dry-run

  # Delete active chats and saved environments with verbose logs:
  ./housekeeping.sh --active-chats --environments --verbose

  # Clean up chat history (with local backup) and all environments:
  ./housekeeping.sh --chat-history --export-history --environments

  # Full housekeeping (all chats, chat history, and environments):
  ./housekeeping.sh --all --verbose
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --archived-chats|--archived) CLEAN_ARCHIVED_CHATS=true ;;
    --active-chats|--active)     CLEAN_ACTIVE_CHATS=true ;;
    --all-chats|--chats)         CLEAN_ARCHIVED_CHATS=true; CLEAN_ACTIVE_CHATS=true ;;
    --chat-history|--history)    CLEAN_CHAT_HISTORY=true ;;
    --environments|--envs)       CLEAN_ENVIRONMENTS=true ;;
    --all|-a)
      CLEAN_ARCHIVED_CHATS=true
      CLEAN_ACTIVE_CHATS=true
      CLEAN_CHAT_HISTORY=true
      CLEAN_ENVIRONMENTS=true
      ;;
    --export-history)            EXPORT_HISTORY=true ;;
    --verbose|--verbous|-v)      VERBOSE=true ;;
    --dry-run|-n)                DRY_RUN=true ;;
    --help|-h)                   usage; exit 0 ;;
    *)
      echo "Unknown argument: $arg (use --help)" >&2
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
  echo "Error: Specify at least one target switch (e.g. --archived-chats, --active-chats, --chat-history, --environments, or --all)." >&2
  usage
  exit 1
fi

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
    HTTP_STATUS=$(curl -sS -w "%{http_code}" -o "$RESP_FILE" \
      --request GET --url "$URL" -u "${API_KEY}:") || {
        log "ERROR: Network failure on GET /v1/agents"
        rm -f "$RESP_FILE"
        exit 1
      }

    if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
      log "ERROR: GET /v1/agents failed (HTTP $HTTP_STATUS): $(cat "$RESP_FILE")"
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

  # Filter chats based on switches
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

      # Inspect or export chat run history & conversation messages when requested or in verbose mode
      if [[ "$CLEAN_CHAT_HISTORY" == "true" || "$VERBOSE" == "true" || "$EXPORT_HISTORY" == "true" ]]; then
        RUNS_FILE=$(mktemp)
        RUNS_STATUS=$(curl -sS -w "%{http_code}" -o "$RUNS_FILE" \
          --request GET --url "${BASE_URL}/v1/agents/${id}/runs?limit=100" -u "${API_KEY}:") || RUNS_STATUS="000"

        if [[ "$RUNS_STATUS" -ge 200 && "$RUNS_STATUS" -lt 300 ]]; then
          RUN_COUNT=$(jq '.items // [] | length' "$RUNS_FILE")
          HISTORY_RUNS_TOTAL=$((HISTORY_RUNS_TOTAL + RUN_COUNT))
          vlog "    [${INDEX}/${CHATS_TARGETED}] Chat history has ${RUN_COUNT} run(s)"

          if [[ "$EXPORT_HISTORY" == "true" ]]; then
            cp "$RUNS_FILE" "${HISTORY_EXPORT_DIR}/${id}_runs.json"
          fi
        fi
        rm -f "$RUNS_FILE"

        # Fetch v0 conversation transcript if exporting history or verbose
        if [[ "$EXPORT_HISTORY" == "true" || "$VERBOSE" == "true" ]]; then
          CONV_FILE=$(mktemp)
          CONV_STATUS=$(curl -sS -w "%{http_code}" -o "$CONV_FILE" \
            --request GET --url "${BASE_URL}/v0/agents/${id}/conversation" -u "${API_KEY}:") || CONV_STATUS="000"
          if [[ "$CONV_STATUS" -ge 200 && "$CONV_STATUS" -lt 300 ]]; then
            MSG_COUNT=$(jq '.messages // [] | length' "$CONV_FILE" 2>/dev/null || echo 0)
            vlog "    [${INDEX}/${CHATS_TARGETED}] Conversation transcript messages: ${MSG_COUNT}"
            if [[ "$EXPORT_HISTORY" == "true" ]]; then
              cp "$CONV_FILE" "${HISTORY_EXPORT_DIR}/${id}_conversation.json"
            fi
          fi
          rm -f "$CONV_FILE"
        fi
      fi

      # Perform cancellation of active run + permanent deletion of chat & its history
      if [[ "$DRY_RUN" == "true" ]]; then
        vlog "    [${INDEX}/${CHATS_TARGETED}] Dry-run: would delete chat ${id} and its history"
        continue
      fi

      if [[ "$status" == "ACTIVE" && -n "$latest_run" && "$latest_run" != "none" ]]; then
        vlog "    [${INDEX}/${CHATS_TARGETED}] Cancelling active run ${latest_run} on chat ${id}..."
        CANCEL_FILE=$(mktemp)
        CANCEL_STATUS=$(curl -sS -w "%{http_code}" -o "$CANCEL_FILE" \
          --request POST --url "${BASE_URL}/v1/agents/${id}/runs/${latest_run}/cancel" -u "${API_KEY}:") || CANCEL_STATUS="000"
        rm -f "$CANCEL_FILE"
        if [[ "$CANCEL_STATUS" -ge 200 && "$CANCEL_STATUS" -lt 300 ]]; then
          RUNS_CANCELLED=$((RUNS_CANCELLED + 1))
          vlog "    [${INDEX}/${CHATS_TARGETED}] Cancelled active run ${latest_run} (HTTP ${CANCEL_STATUS})"
        fi
      fi

      DEL_FILE=$(mktemp)
      DEL_STATUS=$(curl -sS -w "%{http_code}" -o "$DEL_FILE" \
        --request DELETE --url "${BASE_URL}/v1/agents/${id}" -u "${API_KEY}:") || DEL_STATUS="000"
      DEL_BODY=$(cat "$DEL_FILE" 2>/dev/null || true)
      rm -f "$DEL_FILE"

      if [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
        CHATS_DELETED=$((CHATS_DELETED + 1))
        log "    Deleted chat ${id}"
        vlog "    [${INDEX}/${CHATS_TARGETED}] Confirmed DELETE /v1/agents/${id} (HTTP ${DEL_STATUS})"
      else
        CHATS_FAILED=$((CHATS_FAILED + 1))
        log "    FAILED chat ${id} (HTTP ${DEL_STATUS}): ${DEL_BODY}"
      fi
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
    HTTP_STATUS=$(curl -sS -w "%{http_code}" -o "$RESP_FILE" \
      --request GET --url "$URL" -u "${API_KEY}:") || {
        log "ERROR: Network failure on GET /v1/environments"
        rm -f "$RESP_FILE"
        exit 1
      }

    if [[ "$HTTP_STATUS" -lt 200 || "$HTTP_STATUS" -ge 300 ]]; then
      log "ERROR: GET /v1/environments failed (HTTP $HTTP_STATUS): $(cat "$RESP_FILE")"
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
        HIST_STATUS=$(curl -sS -w "%{http_code}" -o "$HIST_FILE" \
          --request GET --url "${BASE_URL}/v1/environments/${env_id}/history?limit=100" -u "${API_KEY}:") || HIST_STATUS="000"
        if [[ "$HIST_STATUS" -ge 200 && "$HIST_STATUS" -lt 300 ]]; then
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

      DEL_FILE=$(mktemp)
      DEL_STATUS=$(curl -sS -w "%{http_code}" -o "$DEL_FILE" \
        --request DELETE --url "${BASE_URL}/v1/environments/${env_id}" -u "${API_KEY}:") || DEL_STATUS="000"
      DEL_BODY=$(cat "$DEL_FILE" 2>/dev/null || true)
      rm -f "$DEL_FILE"

      if [[ "$DEL_STATUS" -ge 200 && "$DEL_STATUS" -lt 300 ]]; then
        ENVS_DELETED=$((ENVS_DELETED + 1))
        log "    Deleted environment ${env_id}"
        vlog "    [${INDEX}/${ENVS_FOUND}] Confirmed DELETE /v1/environments/${env_id} (HTTP ${DEL_STATUS})"
      else
        ENVS_FAILED=$((ENVS_FAILED + 1))
        log "    FAILED environment ${env_id} (HTTP ${DEL_STATUS}): ${DEL_BODY}"
      fi
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
log "Done: chats_deleted=${CHATS_DELETED}/${CHATS_TARGETED} (runs_cancelled=${RUNS_CANCELLED}, history_runs=${HISTORY_RUNS_TOTAL}), envs_deleted=${ENVS_DELETED}/${ENVS_FOUND}, failed=$((CHATS_FAILED + ENVS_FAILED)) | log=${LOG_FILE#$SCRIPT_DIR/}"

[[ $((CHATS_FAILED + ENVS_FAILED)) -eq 0 ]]
