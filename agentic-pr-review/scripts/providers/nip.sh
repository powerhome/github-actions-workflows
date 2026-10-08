#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${REVIEW_JSON_PATH:?}"
: "${REVIEW_PROMPT_PATH:?}"

# The Nitro Intelligence Platform has no agent CLI of its own, so this provider drives the
# Claude Code CLI against the NIP inference gateway's Anthropic-format /v1/messages route.
# The gateway is only reachable from Power's internal network: run it on a self-hosted runner.
NIP_BASE_URL="${NIP_BASE_URL:-https://inference.powerhome.ai}"
NIP_DEFAULT_MODEL="zai-org/GLM-5.3"

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
  echo "PROVIDER_API_KEY is required for the nip provider" >&2
  exit 1
fi

if [[ ! -f "${REVIEW_PROMPT_PATH}" ]]; then
  echo "Review prompt not found: ${REVIEW_PROMPT_PATH}" >&2
  exit 1
fi

model="${MODEL:-${NIP_DEFAULT_MODEL}}"

# The gateway takes its key as a bearer token, which is what ANTHROPIC_AUTH_TOKEN sends.
# An ANTHROPIC_API_KEY left in the environment would be sent as well, so drop it.
unset ANTHROPIC_API_KEY
export ANTHROPIC_BASE_URL="${NIP_BASE_URL}"
export ANTHROPIC_AUTH_TOKEN="${PROVIDER_API_KEY}"

# Claude Code reaches for Anthropic model names for its main loop, subagents and background
# work, and none of them exist on the gateway, so every slot gets the NIP model.
export ANTHROPIC_MODEL="${model}"
export ANTHROPIC_DEFAULT_FABLE_MODEL="${model}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${model}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${model}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${model}"
export CLAUDE_CODE_SUBAGENT_MODEL="${model}"

# The gateway rejects request parameters a model does not allow, rather than ignoring them,
# so keep Claude Code to the plain Messages API: no beta headers, no thinking budget (GLM-5.3
# reasons on its own). Non-essential traffic covers telemetry and error reporting, which
# would otherwise go to Anthropic from a job that is meant to stay on NIP.
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
export MAX_THINKING_TOKENS=0
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Spend-log metadata, per the NIP Client Observability Policy: the keys this run's own logs
# are keyed by, so a gateway spend row can be followed back to the workflow run. No trace id
# and no tags: this client records no Cerebro observations, and the policy forbids a trace id
# Cerebro has never seen and any tag outside its registered vocabulary.
spend_metadata="$(jq -cn \
  --arg repository "${GITHUB_REPOSITORY:-}" \
  --arg pull_request "${PR_NUMBER:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
  '{source: "agentic-pr-review", repository: $repository, pull_request: $pull_request, run_id: $run_id, run_attempt: $run_attempt}')"
export ANTHROPIC_CUSTOM_HEADERS="x-litellm-spend-logs-metadata: ${spend_metadata}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETTINGS_PATH="${ACTION_ROOT}/config/claude-settings.json"

cd "${GITHUB_WORKSPACE}"

PROMPT="$(cat "${REVIEW_PROMPT_PATH}")"
if [[ -n "${REVIEW_ADDITIONAL_INSTRUCTIONS:-}" ]]; then
  PROMPT+=$'\n\n## Additional instructions from the PR comment\n\n'"${REVIEW_ADDITIONAL_INSTRUCTIONS}"
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
  --model "${model}" \
  "${PROMPT}" </dev/null >"${REVIEW_JSON_PATH}"
