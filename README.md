# Cursor Cloud Housekeeping

A unified command-line utility for auditing, exporting, and cleaning up **Cursor Cloud Agents**, **chats (archived & active)**, **chat/run history**, and **saved Cloud Agent environments** via the [Cursor Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints).

---

## Highlights

- **Single Unified CLI (`housekeeping.sh`)**:
  - Consolidates all agent and environment management into one script.
  - Delete all Cloud Agents: `./housekeeping.sh --all-agents` (or `./housekeeping.sh --all-chats`).
  - Selective cleanup: Target only archived agents (`--archived-agents`), only active/idle agents (`--active-agents`), or both.
  - History purge & backup: Purge run & conversation history (`--chat-history`) with optional local JSON export (`--export-history`).
  - Environment cleanup: Delete saved Cloud Agent environments & their change history (`--environments`).
  - One-shot wipe: Clean up everything in one command (`--all`).
- **Readable Error Handling & Hints**:
  - Clear explanations for missing keys, network/TLS errors, rate limits (HTTP 429), permissions (HTTP 403), and server issues (HTTP 5xx), complete with actionable troubleshooting hints (`-> Hint:`).
- **Tested & Verified**:
  - Automated 15-test verification suite running in Docker (`tests/run_tests.sh`) covering all functional and error modes.

---

## Prerequisites

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

## Quick Start

### 1. Clone & Set Up

```bash
git clone https://github.com/RezaOwliaei/cursor-cloud-housekeeping.git
cd cursor-cloud-housekeeping
chmod +x housekeeping.sh
```

### 2. Configure Your API Key

1. Go to [Cursor Dashboard → API Keys](https://cursor.com/dashboard).
2. Generate a User API Key or Service Account API Key.
3. Export it in your environment:

```bash
export CURSOR_API_KEY="your_api_key_here"
```

---

## Usage Guide (`housekeeping.sh`)

### Target Switches

| Switch | Description |
| :--- | :--- |
| `--all-agents`, `--agents` | Delete all Cloud Agents (synonym for `--all-chats`) |
| `--archived-agents` | Delete only archived Cloud Agents (synonym for `--archived-chats`) |
| `--active-agents` | Delete only active/idle Cloud Agents (synonym for `--active-chats`) |
| `--all-chats`, `--chats` | Delete both archived and active/idle Cloud Agent chats |
| `--archived-chats`, `--archived` | Delete only archived Cloud Agent chats (`status=ARCHIVED`) |
| `--active-chats`, `--active` | Delete only active/idle Cloud Agent chats (cancels active runs first) |
| `--chat-history`, `--history` | Inspect & purge chat run/conversation history |
| `--environments`, `--envs` | Delete all saved Cloud Agent environments & their history |
| `-a`, `--all` | Clean up everything (all agents/chats, history, and environments) |

### Options

| Option | Description |
| :--- | :--- |
| `--export-history` | Export conversation & run history JSON to `logs/chat_history_<timestamp>/` before deleting |
| `-v`, `--verbose`, `--verbous` | Show detailed metadata (repos, branch, options), API calls, and cancellation logs |
| `-n`, `--dry-run` | Preview items that would be deleted without making any destructive calls |
| `-h`, `--help` | Show usage help text |

---

## Common Examples

### 1. Delete All Cloud Agents
```bash
# Preview what would be deleted
./housekeeping.sh --all-agents --dry-run

# Delete all agents with concise logs
./housekeeping.sh --all-agents

# Delete all agents with detailed verbose metadata
./housekeeping.sh --all-agents --verbose
```

### 2. Delete Only Archived Agents
```bash
./housekeeping.sh --archived-agents
```

### 3. Delete Only Active/Idle Agents (Leaves Archived Intact)
```bash
./housekeeping.sh --active-agents --verbose
```

### 4. Back Up and Purge Chat History
```bash
# Saves transcripts to logs/chat_history_<timestamp>/ before purging
./housekeeping.sh --chat-history --export-history --verbose
```

### 5. Clean Up Saved Environments
```bash
./housekeeping.sh --environments --verbose
```

### 6. Full Workspace Wipe
```bash
# Preview complete cleanup
./housekeeping.sh --all --dry-run

# Execute full cleanup
./housekeeping.sh --all --verbose
```

---

## Logs

All logs are automatically written to the [`logs/`](./logs) directory (git-ignored):

- `logs/housekeeping_YYYYMMDD_HHMMSS.log`
- `logs/chat_history_YYYYMMDD_HHMMSS/` (when `--export-history` is passed)

---

## Testing in Docker

Run the included automated 15-test suite inside a Docker container:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace <image_id> ./tests/run_tests.sh
```

---

## API References

- [Cursor Cloud Agents API Endpoints](https://cursor.com/docs/cloud-agent/api/endpoints)
- [Cursor Cloud Agents API v0 Reference](https://cursor.com/docs/cloud-agent/api/v0)
