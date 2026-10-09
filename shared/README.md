# Shared agent plumbing

Code used by both [`agentic-pr-review`](../agentic-pr-review) and [`test-plans`](../test-plans). It is not an action of its own.

A caller referencing `powerhome/github-actions-workflows/<action>@<ref>` gets this whole repository at that ref, so each action reaches this directory as `${{ github.action_path }}/../shared` and always runs the copy from its own commit. An action directory copied into another repository has no `../shared`, and its provider and comment steps fail.

## Layout

```
shared/
  bin/run_provider.sh   checks PROVIDER is a bare name and runs providers/<name>.sh
  bin/comment.rb        upserts, creates, or deletes one pull-request comment
  bin/trusted_agent_instructions.rb
                        resets AGENTS.md, CLAUDE.md, .cursor/, .claude/ and the like to the merge base
  providers/            cursor.sh and claude.sh, plus lib/agent.sh for what they share
  config/               read-only CLI permissions for each provider
  lib/                  the comment client and the instruction reset
  spec/
```

## Provider contract

`bin/run_provider.sh` reads:

| Variable | Required | Description |
| --- | --- | --- |
| `PROVIDER` | no | `cursor` (default) or `claude`. |
| `PROVIDER_API_KEY` | yes | Exported as `CURSOR_API_KEY` or `ANTHROPIC_API_KEY`. |
| `AGENT_PROMPT_PATH` | yes | The complete prompt. Keep it outside the workspace, which is the pull request's head. |
| `AGENT_OUTPUT_PATH` | yes | Where the agent's response is written. Anything already there, including a symlink, is removed first. |
| `MODEL` | no | Passed as `--model`; empty leaves the choice to the CLI. |
| `CLAUDE_SETTINGS` | no | Claude only: replaces `config/claude-settings.json`. |
| `CLAUDE_ARGS` | no | Claude only: extra arguments, split with shell quoting. |

Each provider installs its CLI when it is missing, downloading the installer before running it and logging its size and SHA-256. It runs the agent read-only in `GITHUB_WORKSPACE` and fails the step, with the start of the agent's output in the log, if the agent exits non-zero, writes nothing, or writes no JSON object. Parsing the response is left to the calling action.

## Instruction reset

`bin/trusted_agent_instructions.rb` reads `GITHUB_WORKSPACE`, `BASE_SHA`, and `HEAD_SHA`, and needs the merge base fetched. Run it after the last fetch and before any provider: instruction files the pull request edited are restored from the merge base, and ones it added are removed.

## Comment contract

`bin/comment.rb` reads `PR_NUMBER`, `COMMENT_MODE` (`upsert`, `create`, or `delete`), `COMMENT_TAG` (required by `upsert` and `delete`), and exactly one of `COMMENT_BODY` or `COMMENT_BODY_PATH` (required by `upsert` and `create`). A tagged comment carries `<!-- powerhome/github-actions-workflows "<tag>" -->`, so each tag keeps one comment across runs.

## Local Tests

```bash
ruby shared/spec/run_all.rb
```
