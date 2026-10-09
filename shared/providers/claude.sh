#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
: "${AGENT_PROMPT_PATH:?}"
: "${AGENT_OUTPUT_PATH:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_PATH="${SHARED_ROOT}/config/claude-settings.json"

# shellcheck source=lib/agent.sh
source "${SCRIPT_DIR}/lib/agent.sh"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v claude >/dev/null 2>&1; then
  run_installer Claude claude https://claude.ai/install.sh
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

if [[ ! -f "${AGENT_PROMPT_PATH}" ]]; then
  echo "Agent prompt not found: ${AGENT_PROMPT_PATH}" >&2
  exit 1
fi

cd "${GITHUB_WORKSPACE}"

PROMPT="$(cat "${AGENT_PROMPT_PATH}")"

MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

# A caller's workflow can replace the bundled settings, which deny Bash outright: a deny
# rule wins over any --allowed-tools, so loosening the tools means supplying settings too.
if [[ -n "${CLAUDE_SETTINGS:-}" ]]; then
  SETTINGS_PATH="${CLAUDE_SETTINGS}"
fi

# claude-args is split with shell quoting, so --allowed-tools "Bash(gh pr view:*)" stays one
# value, without handing the string to eval.
EXTRA_ARGS=()
if [[ -n "${CLAUDE_ARGS:-}" ]]; then
  extra_args_lines="$(ruby -rshellwords -e 'puts Shellwords.split(ENV.fetch("CLAUDE_ARGS"))')"
  while IFS= read -r arg; do
    EXTRA_ARGS+=("${arg}")
  done <<<"${extra_args_lines}"
fi

echo "[agent] provider: claude" >&2

clear_agent_output

# Read-only permissions come from config/claude-settings.json, passed with --settings rather
# than copied into the workspace, and dontAsk denies every tool it does not allow instead of
# prompting. The working directory is the PR's own checkout, so nothing in it may configure
# the CLI: --setting-sources user skips the repository's .claude/settings*.json, whose hooks
# would run shell commands outside the tool permissions and whose env could repoint the API
# URL at another host, and the settings file disables hooks again in case a future CLI loads
# them from elsewhere. --strict-mcp-config with no --mcp-config keeps the repository's MCP
# servers from loading. claude-settings does not touch those two flags. stdin is /dev/null
# because --print otherwise waits for piped input before it starts. The empty-array
# expansions are spelled out because bash before 4.4 treats "${ARRAY[@]}" on an empty array
# as unbound under set -u.
status=0
claude --print --output-format text \
  --setting-sources user \
  --settings "${SETTINGS_PATH}" \
  --permission-mode dontAsk \
  --strict-mcp-config \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  "${PROMPT}" </dev/null >"${AGENT_OUTPUT_PATH}" || status=$?

check_agent_output claude "${status}"
