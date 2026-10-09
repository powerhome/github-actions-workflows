# Agentic PR Review

Runs a headless review agent against the **merge-base diff** for a pull request, then posts the result as a **GitHub PR review** (summary plus optional inline comments). The default provider is **Cursor** (`agent` CLI with `CURSOR_API_KEY`). **Claude** (`claude` CLI with `ANTHROPIC_API_KEY`) is also supported, and the **NIP** provider runs the same Claude Code CLI against a model on the [Nitro Intelligence Platform](https://github.com/powerhome/nitro-intelligence) inference gateway.

## What it does

1. Creates an installation token for a **GitHub App** (needs repository scopes contents:read and pull_requests:read_write).
2. Loads PR metadata via the GitHub API to resolve the PR base/head refs.
3. Checks out the PR **head** ref, fetches enough history to compute the merge-base with the base branch, removes the checkout's credential from `.git/config`, and writes `pr.diff` (`base...head` three-dot diff).
   Agent-instruction files — `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`, `.cursorrules`, `.cursorignore`, `.cursorindexingignore`, and `.cursor/` and `.claude/` directories at any depth — are then reset to the merge base, so a PR cannot instruct its own reviewer. Their changes are still in `pr.diff` and reviewed like any other.
4. Invokes the configured **provider** via [`shared/providers/<provider>.sh`](../shared/providers) with `prompts/review.md` plus any **additional prompt** text.
5. Parses the agent's JSON output and posts a review on the PR head commit.

Artifacts: uploads `review-agent.json` from the workspace when present (for debugging).

The provider adapters and comment client live in [`shared/`](../shared), beside this action, so reference the action from this repository rather than copying its directory into yours — a copy has no `../shared` to run:

```yaml
- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
```

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `app-id` | yes | GitHub App ID used with `actions/create-github-app-token`. |
| `private-key` | yes | GitHub App private key (PEM). |
| `provider-api-key` | yes | Provider API key (Cursor: becomes `CURSOR_API_KEY`; Claude: becomes `ANTHROPIC_API_KEY`; NIP: an inference gateway key). |
| `pull-request-number` | yes | PR number to review. |
| `provider` | no | Review backend: `cursor`, `claude`, or `nip`. The action resolves it via `shared/providers/<provider>.sh` (default: `cursor`). |
| `deepen-length` | no | Passed to `rmacklin/fetch-through-merge-base` as `deepen_length` (default: `30`). |
| `model` | no | Model passed to the provider CLI's `--model` flag. Empty uses the CLI's default; for NIP, `zai-org/GLM-5.3`. |
| `claude-settings` | no | Claude and NIP only. Settings that replace the bundled read-only [`shared/config/claude-settings.json`](../shared/config/claude-settings.json): a file path relative to the workspace, or a JSON string. See [Overriding the Claude defaults](#overriding-the-claude-defaults). |
| `claude-args` | no | Claude and NIP only. Extra arguments for the `claude` CLI, split with shell quoting, as with `claude-code-action`'s `claude_args`. |
| `additional-prompt` | no | Extra text appended to the review prompt after `prompts/review.md`. |

## Secrets and permissions

- Store **`app-id`**, **`private-key`**, and **`provider-api-key`** as repository (or org) secrets; do not commit them.
- The calling workflow needs permission to **read** contents and **write** pull requests (for posting the review). The GitHub App installation must be allowed to clone the repo and create reviews on the target repository.

## Example Usage

### Review a PR from a pull request event

Use this when your workflow already runs in response to a PR event and you want the action to review that PR.

```yaml
- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_PROVIDER_API_KEY }}
    pull-request-number: ${{ github.event.pull_request.number }}
```

### Review a PR and pass extra instructions

Use `additional-prompt` when you want to append user-supplied context, such as a workflow input or comment body, to the base review prompt.

```yaml
- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
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
- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
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

- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
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
- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider: nip
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_NIP_API_KEY }}
    pull-request-number: ${{ github.event.pull_request.number }}
```

## Status comments

The in-progress and failure comments are posted through `gh` by [`shared/bin/comment.rb`](../shared/bin/comment.rb) rather than a third-party action. The in-progress comment is identified across runs by a marker in its own body (`<!-- powerhome/github-actions-workflows "agentic-pr-review-status" -->`) and cleared by an `always()` step at the end of the run; a comment left by the action this replaced is recognised and adopted. The failure comment carries no marker, so a second failure adds a second comment.

The client is shared with `test-plans/`: both actions are fetched from this repository whole, at the ref a caller pins, so each always runs the copy of `shared/` from its own commit.

## Prompt and output

- Base instructions: `prompts/review.md` (JSON-only response with `summary` and optional inline `comments`).
- If `additional-prompt` is non-empty, it is appended under a short "Additional instructions from the PR comment" section before calling the agent. The combined prompt is written to the runner's temp directory, outside the checkout.
- The provider fails the step, with the first 2 KiB of the agent's output in the log, when the agent exits non-zero, writes nothing, or writes no JSON object.

## Local Tests

Run the whole suite in one process:

```bash
ruby agentic-pr-review/spec/run_all.rb
```

A single file works the same way, since each spec loads the shared helper:

```bash
ruby agentic-pr-review/spec/agent_review_parser_spec.rb
```

The provider adapters and comment client have their own suite:

```bash
ruby shared/spec/run_all.rb
```

The specs run on whatever Ruby is on PATH, as CI does -- the action itself runs on the
runner's preinstalled interpreter. Some specs and scripts use Ruby 3.1+ keyword
shorthand, so 3.1 is the floor.

## CLI permissions

Neither CLI documents a version-pinned installer for CI, so each run installs the latest. The installer is downloaded before it is run, rather than piped into a shell, and the run logs its size and SHA-256; an empty download fails the step instead of running as an empty script.

### Cursor (read-only)

[`shared/config/cursor-cli-config.json`](../shared/config/cursor-cli-config.json) is copied to **`.cursor/cli-config.json`** (the [project-local CLI config](https://cursor.com/docs/cli/reference/permissions) path). It **allows** only `Read(**)` and **denies** `Shell(*)`, `Write(**)`, `Mcp(*:*)`, `WebFetch(*)`, and `WebSearch(*)`, matching the Claude settings below. A `.cursor` symlink in the checkout is replaced rather than written through.

### Claude (read-only)

[`shared/config/claude-settings.json`](../shared/config/claude-settings.json) is passed to `claude` with `--settings`, so nothing is written into the checked-out repository. It **allows** `Read`, `Glob`, and `Grep` and **denies** `Bash`, `Edit`, `Write`, `NotebookEdit`, `WebFetch`, and `WebSearch`. The CLI also runs with:

- `--permission-mode dontAsk`, which denies any tool the settings do not allow instead of waiting on a prompt.
- `--strict-mcp-config` with no `--mcp-config`, so MCP servers configured by the reviewed repository are not loaded.

The CLI runs in the PR's own checkout, so the reviewed repository must not be able to configure it. `--setting-sources user` keeps its `.claude/settings.json` and `.claude/settings.local.json` from loading: their hooks would run shell commands outside the tool permissions, with the API key in the environment, and their `env` could point the API URL at another host. The settings file also sets `disableAllHooks`.

### Overriding the Claude defaults

These apply to the `claude` and `nip` providers. A caller can widen what the agent may do, for example to let it read PR context with `gh`:

```yaml
- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
  with:
    # ...
    provider: claude
    claude-settings: |
      {
        "disableAllHooks": true,
        "permissions": {
          "allow": ["Read", "Glob", "Grep", "Bash(gh pr view:*)", "Bash(gh pr diff:*)"],
          "deny": ["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"]
        }
      }
    claude-args: --max-turns 30
```

- `claude-settings` **replaces** the bundled settings rather than adding to them, and the bundled file denies `Bash` outright. A deny rule wins over any allow, so `--allowed-tools "Bash(...)"` in `claude-args` has no effect unless `claude-settings` also drops that deny.
- `--setting-sources user` and `--strict-mcp-config` are passed regardless, so the reviewed repository still cannot configure the CLI. `claude-args` comes after them, though, so a caller that passes its own `--setting-sources` changes that.
- Whatever the settings allow runs with the API key in the environment, against a prompt built from the PR, so allow only what the review needs.
- The checkout's credential is removed from `.git/config` before the agent runs, so allowed Git commands that need authentication, such as `git fetch`, fail. Local ones — `git log`, `git diff`, `git show` — still work.

### NIP (read-only)

The NIP provider runs the same `claude` CLI, with the same settings and flags, as [Claude](#claude-read-only) above, so the same protections hold, with the gateway key in the environment in place of the Anthropic API key. `claude-settings` and `claude-args` apply to it too.
