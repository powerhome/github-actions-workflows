#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${REVIEW_JSON_PATH:?}"
: "${REVIEW_PROMPT_PATH:?}"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v claude >/dev/null 2>&1; then
  # Anthropic documents this native installer as the supported CLI install path. Like the
  # cursor provider, we take the latest version rather than pinning one.
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="${HOME}/.local/bin:${PATH}"
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found after install" >&2
  exit 1
fi

if [[ -z "${PROVIDER_API_KEY:-}" ]]; then
  echo "PROVIDER_API_KEY is required for the claude provider" >&2
  exit 1
fi

export ANTHROPIC_API_KEY="${PROVIDER_API_KEY}"

if [[ ! -f "${REVIEW_PROMPT_PATH}" ]]; then
  echo "Review prompt not found: ${REVIEW_PROMPT_PATH}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETTINGS_PATH="${ACTION_ROOT}/config/claude-settings.json"

cd "${GITHUB_WORKSPACE}"

PROMPT="$(cat "${REVIEW_PROMPT_PATH}")"
if [[ -n "${REVIEW_ADDITIONAL_INSTRUCTIONS:-}" ]]; then
  PROMPT+=$'\n\n## Additional instructions from the PR comment\n\n'"${REVIEW_ADDITIONAL_INSTRUCTIONS}"
fi

MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

# Read-only permissions come from config/claude-settings.json, passed with --settings rather
# than copied into the workspace. Deny rules win over any settings the reviewed repository
# ships, and dontAsk denies every tool the settings do not allow instead of prompting.
# --strict-mcp-config with no --mcp-config keeps the repository's MCP servers from loading.
# stdin is /dev/null because --print otherwise waits for piped input before it starts.
claude --print --output-format text \
  --settings "${SETTINGS_PATH}" \
  --permission-mode dontAsk \
  --strict-mcp-config \
  "${MODEL_ARGS[@]}" \
  "${PROMPT}" </dev/null >"${REVIEW_JSON_PATH}"
