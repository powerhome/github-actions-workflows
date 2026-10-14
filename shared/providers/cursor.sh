#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${AGENT_PROMPT_PATH:?}"
: "${AGENT_OUTPUT_PATH:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI_CONFIG_TEMPLATE="${SHARED_ROOT}/config/cursor-cli-config.json"

# shellcheck source=lib/agent.sh
source "${SCRIPT_DIR}/lib/agent.sh"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v agent >/dev/null 2>&1; then
  run_installer Cursor cursor https://cursor.com/install
  export PATH="${HOME}/.local/bin:${PATH}"
fi

if ! command -v agent >/dev/null 2>&1; then
  echo "agent CLI not found after install" >&2
  exit 1
fi

if [[ -z "${PROVIDER_API_KEY:-}" ]]; then
  echo "PROVIDER_API_KEY is required for the cursor provider" >&2
  exit 1
fi

export CURSOR_API_KEY="${PROVIDER_API_KEY}"

if [[ ! -f "${AGENT_PROMPT_PATH}" ]]; then
  echo "Agent prompt not found: ${AGENT_PROMPT_PATH}" >&2
  exit 1
fi

cd "${GITHUB_WORKSPACE}"

# The CLI reads a project's permissions from .cursor/cli.json; cli-config.json is only the
# global file's name, under ~/.cursor. The workspace is the pull request's head, which can
# put its own permissions there, or a symlink at .cursor or at the file itself, and both
# mkdir -p and cp follow one. Clearing them first keeps the copy inside the workspace and
# makes it the config the CLI reads.
PROJECT_CONFIG=.cursor/cli.json
if [[ -L .cursor || ( -e .cursor && ! -d .cursor ) ]]; then
  rm -rf -- .cursor
fi
mkdir -p .cursor
rm -rf -- "${PROJECT_CONFIG}"
cp "${CLI_CONFIG_TEMPLATE}" "${PROJECT_CONFIG}"

MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

echo "[agent] provider: cursor" >&2

clear_agent_output

# --trust is required because the headless agent otherwise refuses the workspace.
# Read-only CLI permissions are copied from config/cursor-cli-config.json to
# .cursor/cli.json above. run_agent sends the prompt on stdin. The empty-array expansion
# is spelled out because bash before 4.4 treats "${MODEL_ARGS[@]}" on an empty array as
# unbound under set -u.
invoke_cursor() {
  agent --print --trust --output-format text ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}
}

status=0
run_agent invoke_cursor || status=$?

check_agent_output cursor "${status}"
