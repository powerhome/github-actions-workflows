#!/usr/bin/env bash
#
# Manages a single status comment on a PR for one action run.
#
# Usage:
#   status_comment.sh create   — post an in-progress comment, prints comment_id to stdout
#   status_comment.sh success  — update the comment with completion info
#   status_comment.sh failure  — update the comment with failure info
#
# Env vars required by all commands:
#   GH_TOKEN  GITHUB_REPOSITORY  GITHUB_SERVER_URL  GITHUB_RUN_ID
#   GITHUB_RUN_ATTEMPT  PR_NUMBER  START_TIME
#
# Additional env vars:
#   create:  PROVIDER  MODEL  ACTION_VERSION
#   success: COMMENT_ID  REVIEW_URL (optional)  AGENT_CLI_VERSION (optional)
#   failure: COMMENT_ID  FAILURE_REASON (optional)  AGENT_CLI_VERSION (optional)

set -euo pipefail

COMMAND="${1:?Usage: status_comment.sh <create|success|failure>}"
ACTION_VERSION="${ACTION_VERSION:-1.1.0}"
PROVIDER="${PROVIDER:-cursor}"
MODEL="${MODEL:-default}"

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}"

started_at() {
  # GNU date (-d) on Linux, BSD date (-r) on macOS
  date -u -d "@${START_TIME}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -r "${START_TIME}" +%Y-%m-%dT%H:%M:%SZ
}

format_duration() {
  local secs="${1}"
  if (( secs >= 60 )); then
    echo "$(( secs / 60 ))m $(( secs % 60 ))s"
  else
    echo "${secs}s"
  fi
}

metadata_block() {
  cat <<METADATA
<!-- agentic-pr-review:version=${ACTION_VERSION} -->
<!-- agentic-pr-review:run_id=${GITHUB_RUN_ID} -->
<!-- agentic-pr-review:run_attempt=${GITHUB_RUN_ATTEMPT} -->
<!-- agentic-pr-review:provider=${PROVIDER} -->
<!-- agentic-pr-review:model=${MODEL} -->
<!-- agentic-pr-review:started_at=$(started_at) -->
METADATA
  [[ -n "${AGENT_CLI_VERSION:-}" ]] &&
    echo "<!-- agentic-pr-review:agent_cli_version=${AGENT_CLI_VERSION} -->"
  return 0
}

post_comment() {
  gh api \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
    -F "body=@${1}" \
    --jq '.id'
}

patch_comment() {
  gh api \
    -X PATCH \
    -H "Accept: application/vnd.github+json" \
    "repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}" \
    -F "body=@${1}" \
    > /dev/null
}

tmpfile=$(mktemp)
trap 'rm -f "${tmpfile}"' EXIT

case "${COMMAND}" in
  create)
    cat > "${tmpfile}" <<BODY
:hourglass_flowing_sand: **Agentic PR Review** — in progress

[View workflow run](${run_url})

$(metadata_block)
<!-- agentic-pr-review:status=in_progress -->
BODY
    post_comment "${tmpfile}"
    ;;

  success)
    : "${COMMENT_ID:?COMMENT_ID required}"
    now=$(date +%s)
    duration=$(( now - START_TIME ))
    human=$(format_duration "${duration}")

    links="[View workflow run](${run_url})"
    if [[ -n "${REVIEW_URL:-}" ]]; then
      links="[View review](${REVIEW_URL}) · ${links}"
    fi

    cat > "${tmpfile}" <<BODY
:white_check_mark: **Agentic PR Review** — complete

Review posted in ${human}. ${links}

$(metadata_block)
<!-- agentic-pr-review:completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- agentic-pr-review:duration_seconds=${duration} -->
<!-- agentic-pr-review:status=success -->
BODY
    patch_comment "${tmpfile}"
    ;;

  failure)
    : "${COMMENT_ID:?COMMENT_ID required}"
    now=$(date +%s)
    duration=$(( now - START_TIME ))
    human=$(format_duration "${duration}")

    failure_meta=""
    if [[ -n "${FAILURE_REASON:-}" ]]; then
      escaped=$(echo "${FAILURE_REASON}" | head -1 | tr -d '\n')
      failure_meta="<!-- agentic-pr-review:failure_reason=${escaped} -->"
    fi

    cat > "${tmpfile}" <<BODY
:x: **Agentic PR Review** — failed after ${human}

[View workflow run](${run_url}) for details. If this looks like a transient error, re-run the job. For persistent failures, reach out in [Nitro Dev Discuss](https://nitro.powerhrg.com/connect/#rooms/138).

$(metadata_block)
<!-- agentic-pr-review:completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- agentic-pr-review:duration_seconds=${duration} -->
<!-- agentic-pr-review:status=failure -->
${failure_meta}
BODY
    patch_comment "${tmpfile}"
    ;;

  *)
    echo "Unknown command: ${COMMAND}" >&2
    exit 1
    ;;
esac
