# Agentic PR Review

Runs a headless review agent against the **merge-base diff** for a pull request, then posts the result as a **GitHub PR review** (summary plus optional inline comments). The default provider is **Cursor** (`agent` CLI with `CURSOR_API_KEY`). The **NIP** provider runs the Claude Code CLI against a model on the [Nitro Intelligence Platform](https://github.com/powerhome/nitro-intelligence) inference gateway.

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
| `provider-api-key` | yes | Provider API key (Cursor: becomes `CURSOR_API_KEY`; NIP: an inference gateway key). |
| `pull-request-number` | yes | PR number to review. |
| `provider` | no | Review backend: `cursor` or `nip`. The action resolves it via `scripts/providers/<provider>.sh` (default: `cursor`). |
| `deepen-length` | no | Passed to `rmacklin/fetch-through-merge-base` as `deepen_length` (default: `30`). |
| `model` | no | Model passed to the provider CLI. Empty uses the CLI's default; for NIP, `zai-org/GLM-5.3`. |
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

## NIP provider

`provider: nip` runs the Claude Code CLI against the NIP inference gateway (`https://inference.powerhome.ai`), using its Anthropic-format `/v1/messages` route. Every model slot Claude Code uses is pointed at `model`, which defaults to `zai-org/GLM-5.3`.

- **Runner.** The gateway is only reachable from Power's internal network, so the job must run on a self-hosted runner. The runner also needs what the rest of the action uses: `ruby`, `gh`, `jq`, `git`, and `curl`.
- **Key.** `provider-api-key` is a gateway key issued to an application's `ai-project` team (see [`powerhome/software`](https://github.com/powerhome/software) `modules/ai-project`), not a personal key.
- **Spend logs.** Each request carries an `x-litellm-spend-logs-metadata` header with the repository, PR number and workflow run, so gateway spend can be traced back to a run. It sends no trace ID or tags, since the action records nothing in Cerebro; see the NIP [Client Observability Policy](https://github.com/powerhome/nitro-intelligence/blob/main/docs/client-observability-policy.md).
- **Data handling.** The gateway keeps prompts in its spend logs, and can fail over to third-party providers under load, so the PR diff and any files the agent reads may be served outside Power's datacenters.

```yaml
- uses: ./.github/actions/agentic-pr-review
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider: nip
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_NIP_API_KEY }}
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

### NIP (read-only)

[`config/claude-settings.json`](config/claude-settings.json) is passed to `claude` with `--settings`, so nothing is written into the checked-out repository. It **allows** `Read`, `Glob`, and `Grep` and **denies** `Bash`, `Edit`, `Write`, `NotebookEdit`, `WebFetch`, and `WebSearch`. The CLI also runs with `--permission-mode dontAsk`, which denies any tool the settings do not allow instead of waiting on a prompt, and `--strict-mcp-config` with no `--mcp-config`, so MCP servers configured by the reviewed repository are not loaded.

The CLI runs in the PR's own checkout, so the reviewed repository must not be able to configure it. `--setting-sources user` keeps its `.claude/settings.json` and `.claude/settings.local.json` from loading: their hooks would run shell commands outside the tool permissions, with the gateway key in the environment, and their `env` could point the gateway URL at another host. The settings file also sets `disableAllHooks`.
