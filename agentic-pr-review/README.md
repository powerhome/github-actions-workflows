# Agentic PR Review

Runs a headless review agent against the **merge-base diff** for a pull request, then posts the result as a **GitHub PR review** (summary plus optional inline comments). The default provider is **Cursor** (`agent` CLI with `CURSOR_API_KEY`); **Claude** (`claude` CLI with `ANTHROPIC_API_KEY`) is also supported.

## What it does

1. Creates an installation token for a **GitHub App** (needs repository scopes contents:read and pull_requests:read_write).
2. Loads PR metadata via the GitHub API to resolve the PR base/head refs.
3. Checks out the PR **head** ref, fetches enough history to compute the merge-base with the base branch, decides the [review scope](#follow-up-reviews), removes the checkout's credential from `.git/config`, and writes `pr.diff` (`base...head` three-dot diff), plus `pr-incremental.diff` (`last-reviewed..head`) on a follow-up review.
   Agent-instruction files — `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`, `.cursorrules`, `.cursorignore`, `.cursorindexingignore`, and `.cursor/` and `.claude/` directories at any depth — are then reset to the merge base, so a PR cannot instruct its own reviewer. Their changes are still in `pr.diff` and reviewed like any other.
4. Invokes the configured **provider** via [`shared/providers/<provider>.sh`](../shared/providers) with `prompts/review.md`, the bot's earlier findings, what people have said on the PR, and any **additional prompt** text. On a follow-up review, `pr-incremental.diff` is included in the prompt too. The list of changed files and the whole of `pr.diff` are appended to the prompt, which goes to the CLI on stdin, so the agent cannot review only the part of the diff it chose to open. If the CLI reports the prompt too long for the model's context, the run is retried once with the diff left in `pr.diff` for the agent to page through.
5. Parses the agent's JSON output, drops comments that repeat an open finding (or, on a follow-up review, fall outside the new changes), posts a review on the PR head commit, and replies on earlier threads the agent reports as fixed.

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
| `provider-api-key` | yes, except for Claude with federation | Provider API key (Cursor: becomes `CURSOR_API_KEY`; Claude: becomes `ANTHROPIC_API_KEY`). |
| `pull-request-number` | yes | PR number to review. |
| `provider` | no | Review backend: `cursor` or `claude`. The action resolves it via `shared/providers/<provider>.sh` (default: `cursor`). |
| `deepen-length` | no | Passed to `rmacklin/fetch-through-merge-base` as `deepen_length` (default: `30`). |
| `model` | no | Model passed to the provider CLI's `--model` flag. Empty uses the CLI's default. |
| `effort` | no | Claude only. Effort level passed as `--effort`: `low`, `medium`, `high`, `xhigh`, or `max`. Defaults to `xhigh`; empty uses the CLI's default. |
| `claude-settings` | no | Claude only. Settings that replace the bundled read-only [`shared/config/claude-settings.json`](../shared/config/claude-settings.json): a file path relative to the workspace, or a JSON string. See [Overriding the Claude defaults](#overriding-the-claude-defaults). |
| `anthropic-federation-rule-id` | no | Claude only. Authenticate with [workload identity federation](#review-a-pr-with-claude-using-workload-identity-federation) instead of `provider-api-key`. |
| `anthropic-organization-id` | with a rule | Claude only. Anthropic organization ID. |
| `anthropic-service-account-id` | with a rule | Claude only. The service account the rule authenticates as (`svac_...`). |
| `anthropic-workspace-id` | no | Claude only. Needed when the rule spans more than one workspace (`wrkspc_...`). |
| `claude-args` | no | Claude only. Extra arguments for the `claude` CLI, split with shell quoting, as with `claude-code-action`'s `claude_args`. |
| `additional-prompt` | no | Extra text appended to the review prompt after `prompts/review.md`. |
| `review-scope` | no | `auto` (default) reviews only the commits pushed since the bot's last review, falling back to a full review as described in [Follow-up reviews](#follow-up-reviews). `full` always reviews the whole PR. |

## Secrets and permissions

- Store **`app-id`**, **`private-key`**, and **`provider-api-key`** as repository (or org) secrets; do not commit them. The federation IDs are not secrets, so repository or org variables are fine.
- With federation, the calling job also needs **`id-token: write`**.
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

### Review a PR with Claude using workload identity federation

Pass the federation inputs instead of `provider-api-key`, and grant the job `id-token: write`. The action authenticates with the job's GitHub OIDC token, so no Anthropic API key is stored in GitHub. The federation rule must trust issuer `https://token.actions.githubusercontent.com` with audience `https://api.anthropic.com`, and its subject must match this workflow's repository and event. See [the shared provider notes](../shared/README.md#claude-workload-identity-federation).

```yaml
permissions:
  contents: read
  pull-requests: write
  id-token: write

# ...

- uses: powerhome/github-actions-workflows/agentic-pr-review@<pinned-commit-sha>
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider: claude
    anthropic-federation-rule-id: ${{ vars.ANTHROPIC_FEDERATION_RULE_ID }}
    anthropic-organization-id: ${{ vars.ANTHROPIC_ORGANIZATION_ID }}
    anthropic-service-account-id: ${{ vars.ANTHROPIC_SERVICE_ACCOUNT_ID }}
    anthropic-workspace-id: ${{ vars.ANTHROPIC_WORKSPACE_ID }}
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

## Follow-up reviews

The bot does not re-review what it has already reviewed. Its state lives on the pull request itself, in the marker at the top of each review summary, which records the head it covered and when the run read the PR's comments:

```html
<!-- agentic-pr-review 1.1.0 head=<40-character SHA> seen=<UTC timestamp> -->
```

Only reviews posted by the GitHub App the action authenticates as count, so a marker pasted by anyone else is ignored.

| Situation | Review |
| --- | --- |
| No earlier review by the bot, or its latest summary has no `head=` (posted before 1.1.0) | Full |
| `review-scope: full`, or the run was triggered by `issue_comment` or `workflow_dispatch` (a manual request) | Full |
| The last-reviewed SHA is no longer in the branch's history (rebase or force-push) | Full |
| The last-reviewed SHA is an ancestor of the new head | Incremental: `last-reviewed..head` |
| The head was already reviewed (e.g. a re-run) | Skipped: no agent run. A "no new findings" comment links the last review, and the next real review deletes it |

On an incremental review the agent gets both diffs. It reviews `pr-incremental.diff` but can read `pr.diff` and the rest of the code as context, so it can still catch a new change that breaks older code. Inline comments are only posted on lines that the incremental diff adds **and** the pull request itself changes; anything else is dropped and logged. That second condition keeps out changes merged in from the base branch.

On every review, full or incremental, the agent also gets the bot's earlier inline threads (the most recent 100) with the replies people left on them, plus what people have said on the PR: the inline threads they started and their general comments (the most recent 100 of each). Comments from other bots, and the bot's own status comments, are left out. On an incremental review, people's threads and comments are limited to what is new since `seen=`, since the last review already took the rest into account: a thread is included, in full, only if someone has commented in it since then. The bot's own threads are always included, because whether a finding is fixed or has come back depends on the code, not on new replies. Each comment body is cut at 2,000 characters, and a thread keeps its latest 20 comments.

- **No duplicates.** It is told not to re-raise a finding that one of its threads, or a person's comment, already covers, and to accept a reply that explains the code is intentional. As a backstop, a new comment on the same line as one of the bot's open threads is dropped.
- **Fixed findings are marked.** The agent lists the open threads whose issue is fixed, and the bot replies on each one ("Addressed in `<sha>`") The bot never resolves threads: GitHub only lets an App do that with Contents write, which a reviewer shouldn't need. The thread stays open for a person to resolve, and a hidden marker in the reply tells later reviews the finding was fixed, so it isn't marked twice.
- **Regressions are re-raised.** If an issue the bot marked fixed has come back, the agent raises it again, and the new comment links the original thread. A thread someone resolved before the bot saw it fixed counts as dismissed and is never re-raised.

Anyone who can comment on the PR writes that text, so it goes into the prompt as JSON between randomly named markers, labelled as data rather than instructions. Its effect is limited anyway: the agent can only mark the bot's own open threads as fixed, only after the review has posted, and a reply claiming a fix still has to be checked against the code.

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

[`shared/config/claude-settings.json`](../shared/config/claude-settings.json) is passed to `claude` with `--settings`, so nothing is written into the checked-out repository. It **allows** `Read`, `Glob`, and `Grep` and **denies** `Bash`, `Edit`, `Write`, `NotebookEdit`, `WebFetch`, `WebSearch`, and reading `/proc` (`Read(//proc/**)`), where the process environment and its credentials are. The `/proc` deny, and with federation a deny on the directory holding the OIDC token, are also passed with `--disallowed-tools`, so they hold under replacement settings too. The CLI also runs with:

- `--permission-mode dontAsk`, which denies any tool the settings do not allow instead of waiting on a prompt.
- `--strict-mcp-config` with no `--mcp-config`, so MCP servers configured by the reviewed repository are not loaded.

The CLI runs in the PR's own checkout, so the reviewed repository must not be able to configure it. `--setting-sources user` keeps its `.claude/settings.json` and `.claude/settings.local.json` from loading: their hooks would run shell commands outside the tool permissions, with the API key in the environment, and their `env` could point the API URL at another host. The settings file also sets `disableAllHooks`.

### Read-only `gh` access

On the `claude` provider, the agent can look things up on GitHub that the checkout doesn't have. For example, when a PR bumps a pinned action SHA it can list the pull requests merged upstream between the old and new commits with `gh pr list --repo`, then read them with `gh pr view` and `gh pr diff`, to see what the new revision changes. The prompt gets a section on when and how to use it.

- The commands run with the calling job's `GITHUB_TOKEN`, so they can read what that token can, plus any public repository. None of the allowed commands can write. The action posts with its App token, so the job doesn't need `pull-requests: write` for the review; granting only `read` means a write would also be refused by GitHub if one ever got past the command rules.
- [`shared/config/claude-settings-gh-read.json`](../shared/config/claude-settings-gh-read.json) replaces the bundled settings. It allows the read-only commands `gh pr view`/`diff`/`list`, `gh issue view`/`list`, `gh repo view`, `gh release view`/`list` and `gh search`. It also explicitly denies `gh api`, which can reach any endpoint with any method, `gh auth`, `gh config`, `gh alias`, `gh extension`, clones, checkouts and downloads. Every other shell command is still refused, so the agent can't clone anything or run code.
- The job's token is the only GitHub credential the CLI gets: `GITHUB_TOKEN` and any other `GH_TOKEN` are removed from its environment.
- Before posting, anything in the review that looks like a GitHub token is replaced with `[redacted token]`.
- It is skipped when `claude-settings` is set (the caller decides the tools), on the `cursor` provider, and on a skipped review.

### Overriding the Claude defaults

A caller can widen what the agent may do, for example to let it read PR context with `gh`:

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
- Whatever the settings allow runs with the API key, or with federation the GitHub OIDC request token, in the environment, against a prompt built from the PR, so allow only what the review needs.
- The checkout's credential is removed from `.git/config` before the agent runs, so allowed Git commands that need authentication, such as `git fetch`, fail. Local ones — `git log`, `git diff`, `git show` — still work.
