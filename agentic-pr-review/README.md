# Agentic PR Review

Runs a headless review agent against the **merge-base diff** for a pull request, then posts the result as a **GitHub PR review** (summary plus optional inline comments). The default provider is **Cursor** (`agent` CLI with `CURSOR_API_KEY`); **Claude** (`claude` CLI with `ANTHROPIC_API_KEY`) is also supported.

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
| `provider-api-key` | yes | Provider API key (Cursor: becomes `CURSOR_API_KEY`; Claude: becomes `ANTHROPIC_API_KEY`). |
| `pull-request-number` | yes | PR number to review. |
| `provider` | no | Review backend: `cursor` or `claude`. The action resolves it via `scripts/providers/<provider>.sh` (default: `cursor`). |
| `deepen-length` | no | Passed to `rmacklin/fetch-through-merge-base` as `deepen_length` (default: `30`). |
| `model` | no | Model passed to the provider CLI's `--model` flag. Empty uses the CLI's default. |
| `additional-prompt` | no | Extra text appended to the review prompt after `prompts/review.md`. |

## Secrets and permissions

- Store **`app-id`**, **`private-key`**, and **`provider-api-key`** as repository (or org) secrets; do not commit them.
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

### Review a PR with Claude

Set `provider: claude` and pass an Anthropic API key. `model` is optional; leave it out to use Claude Code's default.

```yaml
- uses: ./.github/actions/agentic-pr-review
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider: claude
    provider-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
    model: claude-opus-5-5
    pull-request-number: ${{ github.event.pull_request.number }}
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

## Status comments

The in-progress and failure comments are posted through `gh` by [`scripts/post_comment.rb`](scripts/post_comment.rb) rather than a third-party action. The in-progress comment is identified across runs by a marker in its own body (`<!-- powerhome/github-actions-workflows "agentic-pr-review-status" -->`) and cleared by an `always()` step at the end of the run; a comment left by the action this replaced is recognised and adopted. The failure comment carries no marker, so a second failure adds a second comment.

`scripts/github_comment_poster.rb` is a deliberate copy of the same client in `test-plans/`. The two actions are versioned and consumed independently, so a fix belongs in both.

## Prompt and output

- Base instructions: `prompts/review.md` (JSON-only response with `summary` and optional inline `comments`).
- If `additional-prompt` is non-empty, it is appended under a short "Additional instructions from the PR comment" section before calling the agent.

## Local Tests

Run the whole suite in one process:

```bash
ruby agentic-pr-review/spec/run_all.rb
```

A single file works the same way, since each spec loads the shared helper:

```bash
ruby agentic-pr-review/spec/github_comment_poster_spec.rb
```

The specs run on whatever Ruby is on PATH, as CI does -- the action itself runs on the
runner's preinstalled interpreter. Some specs and scripts use Ruby 3.1+ keyword
shorthand, so 3.1 is the floor.

## CLI permissions

### Cursor (read-only)

[`config/cli-config.json`](config/cli-config.json) is copied to **`.cursor/cli-config.json`** (the [project-local CLI config](https://cursor.com/docs/cli/reference/permissions) path). It **allows** only `Read(**)` and **denies** `Shell(*)`, `Write(**)`, and `Mcp(*:*)`. Adjust if you need `WebFetch` or specific MCP tools (not included here).

```bash
mkdir -p .cursor
cp path/to/agentic-pr-review/config/cli-config.json .cursor/cli-config.json
```

### Claude (read-only)

[`config/claude-settings.json`](config/claude-settings.json) is passed to `claude` with `--settings`, so nothing is written into the checked-out repository. It **allows** `Read`, `Glob`, and `Grep` and **denies** `Bash`, `Edit`, `Write`, `NotebookEdit`, `WebFetch`, and `WebSearch`. The CLI also runs with:

- `--permission-mode dontAsk`, which denies any tool the settings do not allow instead of waiting on a prompt.
- `--strict-mcp-config` with no `--mcp-config`, so MCP servers configured by the reviewed repository are not loaded.

The CLI runs in the PR's own checkout, so the reviewed repository must not be able to configure it. `--setting-sources user` keeps its `.claude/settings.json` and `.claude/settings.local.json` from loading: their hooks would run shell commands outside the tool permissions, with the API key in the environment, and their `env` could point the API URL at another host. The settings file also sets `disableAllHooks`.
