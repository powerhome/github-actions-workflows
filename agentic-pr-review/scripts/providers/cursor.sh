#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${REVIEW_JSON_PATH:?}"
: "${REVIEW_PROMPT_PATH:?}"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v agent >/dev/null 2>&1; then
  # Cursor documents this installer as the supported CLI install path. We intentionally
  # take the latest version here because the CLI does not currently expose a documented
  # version-pinned install flow that we can rely on in CI.
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

if [[ ! -f "${REVIEW_PROMPT_PATH}" ]]; then
  echo "Review prompt not found: ${REVIEW_PROMPT_PATH}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI_CONFIG_TEMPLATE="${ACTION_ROOT}/config/cli-config.json"
LANGFUSE_HOOKS_ROOT="${ACTION_ROOT}/config/langfuse-hooks"

setup_langfuse_hooks() {
  local destination="${GITHUB_WORKSPACE}/.cursor"
  local source="${LANGFUSE_HOOKS_ROOT}"

  if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to install Langfuse hook dependencies" >&2
    exit 1
  fi

  if [[ ! -f "${source}/hooks.json" ]]; then
    echo "Langfuse hooks configuration not found at ${source}/hooks.json" >&2
    exit 1
  fi

  mkdir -p "${destination}"
  cp "${source}/hooks.json" "${destination}/hooks.json"
  rm -rf "${destination}/hooks"
  cp -R "${source}/hooks" "${destination}/hooks"

  pushd "${destination}/hooks" >/dev/null
  npm ci --ignore-scripts --no-audit --no-fund --prefer-offline --no-progress
  popd >/dev/null
}

cd "${GITHUB_WORKSPACE}"

mkdir -p .cursor
cp "${CLI_CONFIG_TEMPLATE}" .cursor/cli-config.json

LANGFUSE_ENABLED=false
if [[ -n "${LANGFUSE_SECRET_KEY:-}" || -n "${LANGFUSE_PUBLIC_KEY:-}" || -n "${LANGFUSE_BASE_URL:-}" ]]; then
  if [[ -z "${LANGFUSE_SECRET_KEY:-}" || -z "${LANGFUSE_PUBLIC_KEY:-}" ]]; then
    echo "Langfuse tracing skipped: LANGFUSE_SECRET_KEY and LANGFUSE_PUBLIC_KEY are both required" >&2
  else
    LANGFUSE_ENABLED=true
  fi
fi

if [[ "${LANGFUSE_ENABLED}" == "true" ]]; then
  export LANGFUSE_SECRET_KEY LANGFUSE_PUBLIC_KEY
  if [[ -n "${LANGFUSE_BASE_URL:-}" ]]; then
    export LANGFUSE_BASE_URL
  fi
  setup_langfuse_hooks
fi

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
