# Agentic PR Review

Runs a headless review agent against the **merge-base diff** for a pull request, then posts the result as a **GitHub PR review** (summary plus optional inline comments). The default provider is **Cursor** (`agent` CLI with `CURSOR_API_KEY`).

## What it does

1. Creates an installation token for a **GitHub App** (needs repository scopes contents:read and pull_requests:read_write).
2. Loads PR metadata via the GitHub API to resolve the PR base/head refs.
3. Checks out the PR **head** ref, fetches enough history to compute the merge-base with the base branch, and writes `pr.diff` (`base...head` three-dot diff).
4. Invokes the configured **provider** via `scripts/providers/<provider>.sh` with `prompts/review.md` plus any **additional prompt** text.
5. Parses the agent's JSON output and posts a review on the PR head commit.

Artifacts: uploads `review-agent.json` from the workspace when present (for debugging).

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `app-id` | yes | GitHub App ID used with `actions/create-github-app-token`. |
| `private-key` | yes | GitHub App private key (PEM). |
| `provider-api-key` | yes | Provider API key (Cursor: becomes `CURSOR_API_KEY`). |
| `pull-request-number` | yes | PR number to review. |
| `provider` | no | Review backend; the action resolves it via `scripts/providers/<provider>.sh` (default: `cursor`). |
| `deepen-length` | no | Passed to `rmacklin/fetch-through-merge-base` as `deepen_length` (default: `30`). |
| `additional-prompt` | no | Extra text appended to the review prompt after `prompts/review.md`. |
| `langfuse-secret-key` | no | Langfuse secret key; set with `langfuse-public-key` to enable tracing. |
| `langfuse-public-key` | no | Langfuse public key; required when tracing is enabled. |
| `langfuse-base-url` | no | Langfuse base URL (defaults to `https://cloud.langfuse.com`). |

## Secrets and permissions

- Store **`app-id`**, **`private-key`**, and **`provider-api-key`** as repository (or org) secrets; do not commit them.
- If enabling Langfuse tracing, also store **`langfuse-secret-key`** and **`langfuse-public-key`** as secrets.
- The calling workflow needs permission to **read** contents and **write** pull requests (for posting the review). The GitHub App installation must be allowed to clone the repo and create reviews on the target repository.

## Example Usage

### Review a PR from a pull request event

Use this when your workflow already runs in response to a PR event and you want the action to review that PR.

```yaml
- uses: ./.github/actions/agentic-pr-review
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_PROVIDER_API_KEY }}
    pull-request-number: ${{ github.event.pull_request.number }}
```

### Review a PR and pass extra instructions

Use `additional-prompt` when you want to append user-supplied context, such as a workflow input or comment body, to the base review prompt.

```yaml
- uses: ./.github/actions/agentic-pr-review
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_PROVIDER_API_KEY }}
    pull-request-number: ${{ github.event.issue.number }}
    additional-prompt: ${{ github.event.comment.body }}
```

Use `github.event.pull_request.number` when the workflow runs on `pull_request` events. Use `github.event.issue.number` for `issue_comment` events on a pull request.

### Skip ineligible pull requests before invoking the action

If your workflow should avoid reviewing draft or closed pull requests, add a small skip step before invoking this action.

```yaml
- name: Skip ineligible PRs
  id: skip_gate
  if: |
    (github.event.pull_request.state || github.event.issue.state) != 'open' ||
    (github.event.pull_request.draft || github.event.issue.draft)
  run: |
    echo "skip=true" >> "${GITHUB_OUTPUT}"
    echo "Skipping agentic review because the PR is not open or is draft"

- uses: ./.github/actions/agentic-pr-review
  if: steps.skip_gate.outputs.skip != 'true'
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_PROVIDER_API_KEY }}
    pull-request-number: ${{ github.event.pull_request.number }}
```

## Prompt and output

- Base instructions: `prompts/review.md` (JSON-only response with `summary` and optional inline `comments`).
- If `additional-prompt` is non-empty, it is appended under a short "Additional instructions from the PR comment" section before calling the agent.

## CLI permissions

### Cursor (read-only)

[`config/cli-config.json`](config/cli-config.json) is copied to **`.cursor/cli-config.json`** (the [project-local CLI config](https://cursor.com/docs/cli/reference/permissions) path). It **allows** only `Read(**)` and **denies** `Shell(*)`, `Write(**)`, and `Mcp(*:*)`. Adjust if you need `WebFetch` or specific MCP tools (not included here).

```bash
mkdir -p .cursor
cp path/to/agentic-pr-review/config/cli-config.json .cursor/cli-config.json
```

## Langfuse tracing (Cursor)

Provide `langfuse-secret-key` and `langfuse-public-key` inputs to trace Cursor agent activity to Langfuse. When both are present, the action:

- Copies the bundled Cursor hooks from `config/langfuse-hooks` into `.cursor/`
- Installs hook dependencies with `npm ci` before invoking the Cursor CLI
- Exports `LANGFUSE_*` variables (optional `langfuse-base-url` overrides the default `https://cloud.langfuse.com`)

If the keys are omitted, Langfuse tracing is skipped and the review runs as before.
