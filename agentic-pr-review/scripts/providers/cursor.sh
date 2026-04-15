#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${REVIEW_JSON_PATH:?}"
: "${REVIEW_PROMPT_PATH:?}"

report_error() {
  echo "${1}" >&2
  if [[ -n "${ERROR_FILE:-}" ]]; then
    echo "${1}" > "${ERROR_FILE}"
  fi
}

# Write a generic message for unexpected failures (e.g. agent CLI crash) unless
# a specific error was already reported via report_error.
trap 'rc=$?; if [[ $rc -ne 0 && -n "${ERROR_FILE:-}" && ! -s "${ERROR_FILE}" ]]; then report_error "Review provider (cursor) exited with code ${rc}"; fi' EXIT

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v agent >/dev/null 2>&1; then
  # Cursor documents this installer as the supported CLI install path. We intentionally
  # take the latest version here because the CLI does not currently expose a documented
  # version-pinned install flow that we can rely on in CI.
  curl https://cursor.com/install -fsS | bash
  export PATH="${HOME}/.local/bin:${PATH}"
fi

if ! command -v agent >/dev/null 2>&1; then
  report_error "agent CLI not found after install"
  exit 1
fi

if [[ -z "${PROVIDER_API_KEY:-}" ]]; then
  report_error "PROVIDER_API_KEY is required for the cursor provider"
  exit 1
fi

export CURSOR_API_KEY="${PROVIDER_API_KEY}"

if [[ ! -f "${REVIEW_PROMPT_PATH}" ]]; then
  report_error "Review prompt not found: ${REVIEW_PROMPT_PATH}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI_CONFIG_TEMPLATE="${ACTION_ROOT}/config/cli-config.json"

cd "${GITHUB_WORKSPACE}"

mkdir -p .cursor
cp "${CLI_CONFIG_TEMPLATE}" .cursor/cli-config.json

PROMPT="$(cat "${REVIEW_PROMPT_PATH}")"
if [[ -n "${REVIEW_ADDITIONAL_INSTRUCTIONS:-}" ]]; then
  PROMPT+=$'\n\n## Additional instructions from the PR comment\n\n'"${REVIEW_ADDITIONAL_INSTRUCTIONS}"
fi

MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

# --trust is required: headless agent refuses to run unless the workspace is trusted.
# Read-only CLI permissions via .cursor/cli-config.json (copied from config/cli-config.json).
agent --print --trust --output-format text "${MODEL_ARGS[@]}" "${PROMPT}" >"${REVIEW_JSON_PATH}"
