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

FEDERATION_VARS=(
  ANTHROPIC_FEDERATION_RULE_ID
  ANTHROPIC_ORGANIZATION_ID
  ANTHROPIC_SERVICE_ACCOUNT_ID
  ANTHROPIC_WORKSPACE_ID
)

# A composite step sets every variable its env names, so an input the caller left out
# arrives empty. An empty credential variable still takes its place in the CLI's
# precedence, so these are removed rather than passed on.
for name in "${FEDERATION_VARS[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    unset "${name}"
  fi
done

if [[ -n "${PROVIDER_API_KEY:-}" && -n "${ANTHROPIC_FEDERATION_RULE_ID:-}" ]]; then
  echo "The claude provider takes either PROVIDER_API_KEY or ANTHROPIC_FEDERATION_RULE_ID, not both" >&2
  exit 1
fi

# GitHub's OIDC tokens last about five minutes and carry a jti, which Anthropic accepts
# only once, while the access token minted from one lasts at most twice the JWT's
# remaining life. The CLI exchanges again shortly before its token expires, reading
# ANTHROPIC_IDENTITY_TOKEN_FILE each time, so the file has to hold a JWT that is both
# unexpired and unused whenever it looks: one minted at most a minute ago is.
IDENTITY_TOKEN_AUDIENCE="https%3A%2F%2Fapi.anthropic.com"
IDENTITY_TOKEN_REFRESH_SECONDS=60

# The request token is sent with --config on stdin rather than as an argument, so it is
# not in this curl's command line for another process to read. The JWT is written beside
# the file and renamed over it, so the CLI never reads a partial one.
fetch_identity_token() {
  local path="$1"

  # shellcheck disable=SC2016 # the Ruby is in single quotes on purpose
  printf 'header = "Authorization: bearer %s"\n' "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" |
    curl -fsS --retry 3 --config - "${ACTIONS_ID_TOKEN_REQUEST_URL:-}&audience=${IDENTITY_TOKEN_AUDIENCE}" |
    ruby -rjson -e 'print JSON.parse($stdin.read).fetch("value")' >"${path}.next" || return 1

  [[ -s "${path}.next" ]] || return 1
  mv -f "${path}.next" "${path}"
}

# sleep writes to /dev/null so an orphaned sleep, left behind when this loop is killed,
# holds no pipe of the step's open.
refresh_identity_token() {
  local path="$1"

  while sleep "${IDENTITY_TOKEN_REFRESH_SECONDS}" >/dev/null 2>&1; do
    if ! fetch_identity_token "${path}"; then
      echo "[agent] Could not refresh the GitHub OIDC token; the previous one stays in place" >&2
    fi
  done
}

# Read, Glob and Grep are allowed everywhere else, so a prompt-injected agent could find a
# credential on disk and put it in its output. These denies go on the command line rather
# than in config/claude-settings.json, which a caller's claude-settings replaces. /proc
# holds this script's environment, with the API key or the OIDC request token.
DENIED_READS=("Read(//proc/**)")

if [[ -n "${PROVIDER_API_KEY:-}" ]]; then
  unset "${FEDERATION_VARS[@]}" ANTHROPIC_IDENTITY_TOKEN ANTHROPIC_IDENTITY_TOKEN_FILE
  export ANTHROPIC_API_KEY="${PROVIDER_API_KEY}"
elif [[ -n "${ANTHROPIC_FEDERATION_RULE_ID:-}" ]]; then
  for name in ANTHROPIC_ORGANIZATION_ID ANTHROPIC_SERVICE_ACCOUNT_ID; do
    if [[ -z "${!name:-}" ]]; then
      echo "${name} is required alongside ANTHROPIC_FEDERATION_RULE_ID" >&2
      exit 1
    fi
  done

  if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
    echo "Anthropic federation needs a GitHub OIDC token: give the calling job 'permissions: id-token: write'" >&2
    exit 1
  fi

  # Each of these outranks federation in the CLI, and a caller's job env reaches this step.
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_IDENTITY_TOKEN

  identity_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-identity.XXXXXX")"
  # Canonical, so the deny below names the path the CLI resolves a read to: TMPDIR can
  # end in a slash or run through a symlink.
  identity_dir="$(cd "${identity_dir}" && pwd -P)"
  export ANTHROPIC_IDENTITY_TOKEN_FILE="${identity_dir}/github-oidc.jwt"
  # The file always holds a JWT that has not been exchanged yet, good for anyone who
  # reads it for the next few minutes. identity_dir starts with /, so one more makes the
  # rule's // absolute-path prefix.
  DENIED_READS+=("Read(/${identity_dir}/**)")

  if ! fetch_identity_token "${ANTHROPIC_IDENTITY_TOKEN_FILE}"; then
    rm -rf -- "${identity_dir}"
    echo "Could not fetch a GitHub OIDC token for Anthropic federation" >&2
    exit 1
  fi

  refresh_identity_token "${ANTHROPIC_IDENTITY_TOKEN_FILE}" &
  identity_refresher=$!
  # Out of the job table, so bash does not report it as Terminated when the trap kills it.
  disown "${identity_refresher}"
  # shellcheck disable=SC2064 # expanded now, while both are in scope
  trap "kill '${identity_refresher}' 2>/dev/null || true; rm -rf -- '${identity_dir}'" EXIT

  echo "[agent] claude auth: Anthropic workload identity federation" >&2
else
  echo "The claude provider needs PROVIDER_API_KEY or ANTHROPIC_FEDERATION_RULE_ID" >&2
  exit 1
fi

if [[ ! -f "${AGENT_PROMPT_PATH}" ]]; then
  echo "Agent prompt not found: ${AGENT_PROMPT_PATH}" >&2
  exit 1
fi

cd "${GITHUB_WORKSPACE}"

MODEL_ARGS=()
if [[ -n "${MODEL:-}" ]]; then
  MODEL_ARGS+=(--model "${MODEL}")
fi

# Ahead of claude-args, like --model.
if [[ -n "${EFFORT:-}" ]]; then
  MODEL_ARGS+=(--effort "${EFFORT}")
fi

# A caller's workflow can replace the bundled settings, which allow no shell command but
# upstream: dontAsk refuses anything they do not allow, so loosening the tools means
# supplying settings too.
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
# servers from loading. claude-settings does not touch those two flags. run_agent sends the
# prompt on stdin. The empty-array expansions are spelled out because bash before 4.4
# treats "${ARRAY[@]}" on an empty array as unbound under set -u. --disallowed-tools takes
# every argument up to the next flag, so it is followed by one. The CLI gets no
# ACTIONS_ID_TOKEN_REQUEST_* variables, which would let it mint GitHub OIDC tokens for any
# audience; the refresher above keeps them.
invoke_claude() {
  env -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    claude --print --output-format text \
      --disallowed-tools "${DENIED_READS[@]}" \
      --setting-sources user \
      --settings "${SETTINGS_PATH}" \
      --permission-mode dontAsk \
      --strict-mcp-config \
      ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
      ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
}

status=0
run_agent invoke_claude || status=$?

check_agent_output claude "${status}"
