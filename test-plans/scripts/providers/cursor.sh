#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${TEST_PLAN_JSON_PATH:?}"
: "${TEST_PLAN_PROMPT_PATH:?}"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v agent >/dev/null 2>&1; then
  # Cursor does not currently document a version-pinned CLI installer for CI.
  curl https://cursor.com/install -fsS | bash
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

if [[ ! -f "${TEST_PLAN_PROMPT_PATH}" ]]; then
  echo "Test-plan prompt not found: ${TEST_PLAN_PROMPT_PATH}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI_CONFIG_TEMPLATE="${ACTION_ROOT}/config/cli-config.json"

cd "${GITHUB_WORKSPACE}"

mkdir -p .cursor
cp "${CLI_CONFIG_TEMPLATE}" .cursor/cli-config.json

PROMPT="$(cat "${TEST_PLAN_PROMPT_PATH}")"

MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

# --trust is required because the headless agent otherwise refuses the workspace.
# Read-only CLI permissions are copied from config/cli-config.json.
agent --print --trust --output-format text "${MODEL_ARGS[@]}" "${PROMPT}" >"${TEST_PLAN_JSON_PATH}"
