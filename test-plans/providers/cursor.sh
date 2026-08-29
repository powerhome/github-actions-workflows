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
ACTION_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI_CONFIG_TEMPLATE="${ACTION_ROOT}/config/cli-config.json"

cd "${GITHUB_WORKSPACE}"

mkdir -p .cursor
cp "${CLI_CONFIG_TEMPLATE}" .cursor/cli-config.json

PROMPT="$(cat "${TEST_PLAN_PROMPT_PATH}")"

# The standard profile pins no model, so this array is routinely empty. Expanding an
# empty array as "${MODEL_ARGS[@]}" under `set -u` is only safe from bash 4.4 on; the
# runner has bash 5, but macOS still ships 3.2, where it aborts the script.
MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

# Named so a run's logs show which model actually answered, without reading the profile.
MODEL_LABEL="${MODEL:-cursor default}"
echo "[test_plan] provider: cursor, model: ${MODEL_LABEL}" >&2

# --trust is required because the headless agent otherwise refuses the workspace.
# Read-only CLI permissions are copied from config/cli-config.json.
status=0
agent --print --trust --output-format text \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  "${PROMPT}" >"${TEST_PLAN_JSON_PATH}" || status=$?

# The agent writes its own diagnostics to stdout, which the redirect above captures
# into the output file rather than the log. Without echoing the file back, a rejected
# model or a refused workspace surfaces as a bare exit code here, or as a confusing
# parse error two steps later.
preview_output() {
  echo "[test_plan] First 2 KiB of the agent's output:" >&2
  head -c 2048 "${TEST_PLAN_JSON_PATH}" >&2 || true
  echo >&2
}

if [[ "${status}" -ne 0 ]]; then
  echo "The cursor agent failed with exit ${status} using model '${MODEL_LABEL}'." >&2
  preview_output
  exit "${status}"
fi

if [[ ! -s "${TEST_PLAN_JSON_PATH}" ]]; then
  echo "The cursor agent exited 0 but produced no output using model '${MODEL_LABEL}'." >&2
  exit 1
fi

# The parser recovers JSON from fences and surrounding prose, so this only has to rule
# out a response that contains no object at all.
if ! grep -q "{" "${TEST_PLAN_JSON_PATH}"; then
  echo "The cursor agent returned no JSON object using model '${MODEL_LABEL}'." >&2
  preview_output
  exit 1
fi
