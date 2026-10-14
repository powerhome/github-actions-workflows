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
| `PROVIDER_API_KEY` | yes, except for Claude with federation | Exported as `CURSOR_API_KEY` or `ANTHROPIC_API_KEY`. |
| `ANTHROPIC_FEDERATION_RULE_ID` | no | Claude only: authenticate with [workload identity federation](#claude-workload-identity-federation) instead of `PROVIDER_API_KEY`. |
| `ANTHROPIC_ORGANIZATION_ID` | with a rule | Claude only. |
| `ANTHROPIC_SERVICE_ACCOUNT_ID` | with a rule | Claude only. |
| `ANTHROPIC_WORKSPACE_ID` | no | Claude only: needed when the rule spans more than one workspace. |
| `AGENT_PROMPT_PATH` | yes | The complete prompt. Keep it outside the workspace, which is the pull request's head. |
| `AGENT_OUTPUT_PATH` | yes | Where the agent's response is written. Anything already there, including a symlink, is removed first. |
| `MODEL` | no | Passed as `--model`; empty leaves the choice to the CLI. |
| `EFFORT` | no | Claude only: passed as `--effort`; empty leaves the choice to the CLI. Both actions default to `xhigh`. |
| `CLAUDE_SETTINGS` | no | Claude only: replaces `config/claude-settings.json`. |
| `CLAUDE_ARGS` | no | Claude only: extra arguments, split with shell quoting. |

Each provider installs its CLI when it is missing, downloading the installer before running it and logging its size and SHA-256. It runs the agent read-only in `GITHUB_WORKSPACE` and fails the step, with the start of the agent's output in the log, if the agent exits non-zero, writes nothing, or writes no JSON object. Parsing the response is left to the calling action.

### Claude workload identity federation

With `ANTHROPIC_FEDERATION_RULE_ID` set and `PROVIDER_API_KEY` empty, the Claude provider authenticates as an Anthropic service account using the job's GitHub OIDC token, so no Anthropic API key is stored in GitHub. The calling job needs `permissions: id-token: write`, and the federation rule must accept the job's token: issuer `https://token.actions.githubusercontent.com`, audience `https://api.anthropic.com`, and a subject that matches the calling repository and event.

The `claude` CLI does the token exchange itself, reading the JWT from `ANTHROPIC_IDENTITY_TOKEN_FILE`. GitHub's tokens last about five minutes and each can be exchanged only once, and the access token minted from one lasts at most twice the JWT's remaining life, so the provider writes a fresh JWT to that file every minute while the agent runs. The file is in a private temporary directory removed when the provider exits. The CLI itself does not get the `ACTIONS_ID_TOKEN_REQUEST_*` variables, and it runs with `--disallowed-tools` denying reads of that directory and of `/proc`, where the parent shell's copy of the variables is. Read, Glob and Grep are allowed everywhere else, so without these a prompt-injected agent could find an unused JWT and post it in its output. They are passed on the command line, not in the settings file, so a caller's `claude-settings` cannot drop them.

Setting both `PROVIDER_API_KEY` and a federation rule is an error. Empty federation variables, which is what a composite action passes for an input that was left out, are removed before the CLI starts, because an empty credential variable still takes its place in the CLI's precedence. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, and `ANTHROPIC_PROFILE` from the caller's job env are removed for the same reason.

## Instruction reset

`bin/trusted_agent_instructions.rb` reads `GITHUB_WORKSPACE`, `BASE_SHA`, and `HEAD_SHA`, and needs the merge base fetched. Run it after the last fetch and before any provider: instruction files the pull request edited are restored from the merge base, and ones it added are removed.

## Comment contract

`bin/comment.rb` reads `PR_NUMBER`, `COMMENT_MODE` (`upsert`, `create`, or `delete`), `COMMENT_TAG` (required by `upsert` and `delete`), and exactly one of `COMMENT_BODY` or `COMMENT_BODY_PATH` (required by `upsert` and `create`). A tagged comment carries `<!-- powerhome/github-actions-workflows "<tag>" -->`, so each tag keeps one comment across runs.

## Local Tests

```bash
ruby shared/spec/run_all.rb
```
