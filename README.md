# Cursor Cloud Housekeeping

Command-line bash utilities for auditing, exporting, and cleaning up **Cursor Cloud Agents**, **chats (archived & active)**, **chat/run history**, and **saved Cloud Agent environments** via the [Cursor Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints).

---

## Features

- **List & Delete All Cloud Agents (`delete_all_agents.sh`)**:
  - Paginates through all Cloud Agents (`GET /v1/agents?includeArchived=true`).
  - Displays each agent's status (`ACTIVE`, `IDLE`, `ARCHIVED`) and whether it is archived (`yes` / `no`).
  - Permanently deletes all discovered agents (`DELETE /v1/agents/{id}`).
- **Granular Workspace Housekeeping (`housekeeping.sh`)**:
  - **Selective Chat Cleanup**: Target only archived chats (`--archived-chats`), only active/idle chats (`--active-chats`), or all chats (`--all-chats`).
  - **Chat & Run History Cleanup**: Inspects run history (`GET /v1/agents/{id}/runs`) and conversation transcripts (`GET /v0/agents/{id}/conversation`), cancels active runs (`POST /v1/agents/{id}/runs/{runId}/cancel`), optionally exports a local JSON backup (`--export-history`), and purges server-side history.
  - **Environments Cleanup**: Lists and permanently deletes saved Cloud Agent environments (`GET /v1/environments`, `DELETE /v1/environments/{id}`) along with their configuration history.
- **Noise-Free & Verbose Logging**:
  - Compact, timestamped logs by default, automatically saved under the `logs/` folder.
  - Pass `--verbose` (`-v`) for full metadata inspection, pagination details, active run cancellation logs, and per-request HTTP statuses.
  - Pass `--dry-run` (`-n`) to safely preview actions without deleting any resources.

---

## Prerequisites

Make sure the following standard CLI tools are installed on your system:

- `bash` (4.0+ or macOS default `/usr/bin/env bash`)
- `curl`
- `jq`

On macOS (via Homebrew):
```bash
brew install curl jq
```

On Ubuntu/Debian:
```bash
sudo apt-get update && sudo apt-get install -y curl jq
```

---

## Step-by-Step Usage Guide

### Step 1: Clone the Repository

```bash
git clone https://github.com/RezaOwliaei/cursor-cloud-housekeeping.git
cd cursor-cloud-housekeeping
chmod +x delete_all_agents.sh housekeeping.sh
```

### Step 2: Configure Your Cursor API Key

1. Open [Cursor Dashboard → API Keys](https://cursor.com/dashboard).
2. Generate a User API Key or Service Account API Key.
3. Export `CURSOR_API_KEY` in your terminal session:

```bash
export CURSOR_API_KEY="your_cursor_api_key_here"
```

---

### Step 3: List & Delete All Agents (`delete_all_agents.sh`)

#### Options

| Flag | Description |
| :--- | :--- |
| `-n`, `--dry-run` | List all agents and their archived status without deleting anything |
| `-v`, `--verbose`, `--verbous` | Log detailed agent metadata (repos, branches, timestamps, run IDs) and deletion steps |
| `-h`, `--help` | Display help text |

#### Examples

**1. Preview all agents (dry run):**
```bash
./delete_all_agents.sh --dry-run
```

**2. Delete all agents with concise logs:**
```bash
./delete_all_agents.sh
```
*Sample Output:*
```text
[16:05:01] Step 1/2: Listing agents...
[16:05:02] Found 2 agent(s) (archived: 1, non-archived: 1)
[16:05:02]   - bc-0001 | status=ACTIVE | archived=no | Fix auth bug
[16:05:02]   - bc-0002 | status=ARCHIVED | archived=yes | Add README
[16:05:02] Step 2/2: Deleting 2 agent(s)...
[16:05:03]   - Deleted bc-0001
[16:05:03]   - Deleted bc-0002
[16:05:03] Done: total=2 (archived=1, non_archived=1), deleted=2, failed=0 | log=logs/delete_agents_20261017_160501.log
```

**3. Delete all agents with detailed verbose logs:**
```bash
./delete_all_agents.sh --verbose
```
*Sample Output:*
```text
[16:06:10] [VERBOSE] Initialized with BASE_URL=https://api.cursor.com, DRY_RUN=false, LOG_FILE=logs/delete_agents_20261017_160610.log
[16:06:10] Step 1/2: Listing agents...
[16:06:10] [VERBOSE] Requesting page 1: GET https://api.cursor.com/v1/agents?limit=100&includeArchived=true
[16:06:11] [VERBOSE] Page 1 returned 1 agent(s) (HTTP 200)
[16:06:11] Found 1 agent(s) (archived: 0, non-archived: 1)
[16:06:11] [VERBOSE] Status breakdown: ACTIVE=1, IDLE=0, ARCHIVED=0
[16:06:11]   - bc-0001 | status=ACTIVE | archived=no | Fix auth bug
[16:06:11] [VERBOSE]     [1/1] Details for bc-0001:
[16:06:11] [VERBOSE]       Name         : Fix auth bug
[16:06:11] [VERBOSE]       Status       : ACTIVE (Archived: no)
[16:06:11] [VERBOSE]       Environment  : cloud
[16:06:11] [VERBOSE]       Created At   : 2026-10-17T14:20:00.000Z
[16:06:11] [VERBOSE]       Updated At   : 2026-10-17T14:25:00.000Z
[16:06:11] [VERBOSE]       Latest Run   : run-0001
[16:06:11] [VERBOSE]       Dashboard URL: https://cursor.com/agents/bc-0001
[16:06:11] [VERBOSE]       Repositories : https://github.com/org/repo (ref: main)
[16:06:11] [VERBOSE]       Options      : autoCreatePR=true, workOnCurrentBranch=false
[16:06:11] Step 2/2: Deleting 1 agent(s)...
[16:06:11] [VERBOSE] [1/1] Preparing to delete agent bc-0001 ('Fix auth bug', status=ACTIVE, archived=no)
[16:06:11] [VERBOSE] [1/1] Agent bc-0001 is ACTIVE (run run-0001); attempting run cancellation before delete...
[16:06:12] [VERBOSE] [1/1] Cancel run run-0001 returned HTTP 200
[16:06:12] [VERBOSE] [1/1] Sending DELETE https://api.cursor.com/v1/agents/bc-0001
[16:06:12]   - Deleted bc-0001
[16:06:12] [VERBOSE] [1/1] Confirmed permanent deletion of bc-0001 ('Fix auth bug') — HTTP 200, response={"id":"bc-0001"}
[16:06:12] Done: total=1 (archived=0, non_archived=1), deleted=1, failed=0 | log=logs/delete_agents_20261017_160610.log
```

---

### Step 4: Targeted Housekeeping (`housekeeping.sh`)

Use `housekeeping.sh` when you want fine-grained control over cleaning up archived chats, active chats, chat/run history, and saved Cloud Agent environments.

#### Switches & Options

| Switch / Flag | Description |
| :--- | :--- |
| `--archived-chats`, `--archived` | Delete only archived Cloud Agent chats (`status=ARCHIVED`) |
| `--active-chats`, `--active` | Delete only active/idle (non-archived) Cloud Agent chats |
| `--all-chats`, `--chats` | Delete both archived and active/idle Cloud Agent chats |
| `--chat-history`, `--history` | Inspect & purge chat run/conversation history (cancels active runs) |
| `--environments`, `--envs` | Delete all saved Cloud Agent environments & their history |
| `-a`, `--all` | Clean up everything (all chats, chat history, and saved environments) |
| `--export-history` | Export conversation & run history JSON to `logs/chat_history_<timestamp>/` before deleting |
| `-v`, `--verbose`, `--verbous` | Show detailed metadata, run/chat history counts, and deletion progress |
| `-n`, `--dry-run` | Preview items to be cleaned up without deleting anything |
| `-h`, `--help` | Show help message |

#### Examples

**1. Delete only archived chats:**
```bash
./housekeeping.sh --archived-chats
```

**2. Delete only active/idle chats (preview first with `--dry-run`):**
```bash
./housekeeping.sh --active-chats --dry-run
./housekeeping.sh --active-chats --verbose
```

**3. Clean up all saved Cloud Agent environments:**
```bash
./housekeeping.sh --environments --verbose
```

**4. Back up and purge all chat history:**
```bash
./housekeeping.sh --chat-history --export-history --verbose
```

**5. Complete workspace housekeeping (chats + history + environments):**
```bash
./housekeeping.sh --all --verbose
```

---

## Logs

All execution logs (and optional chat history exports) are automatically written to the [`logs/`](./logs) directory (git-ignored by default):

- `logs/delete_agents_YYYYMMDD_HHMMSS.log`
- `logs/housekeeping_YYYYMMDD_HHMMSS.log`
- `logs/chat_history_YYYYMMDD_HHMMSS/` (when `--export-history` is used)

---

## API Reference

- [Cursor Cloud Agents API v1 Endpoints](https://cursor.com/docs/cloud-agent/api/endpoints)
- [Cursor Cloud Agents API v0 Reference](https://cursor.com/docs/cloud-agent/api/v0)
