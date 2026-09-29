# GitHub Actions Workflows

Reusable GitHub Actions for building packages, reviewing pull requests, and producing manual QA test plans. The action directories contain their composite action definitions; `docs/` contains the published usage guides.

| Action | Purpose |
| --- | --- |
| [`test-plans/`](test-plans/README.md) | Generate and maintain a manual QA plan on a pull request. |
| [`agentic-pr-review/`](agentic-pr-review/README.md) | Post an AI-assisted pull request review. |
| [`build-ruby-gem/`](docs/ruby-gem.md) | Build Ruby gems. |

## How test plans are made

The [`test-plans/action.yml`](test-plans/action.yml) steps follow this path:

| Step | Owner | Information handed to the next step |
| --- | --- | --- |
| Resolve the profile and check mergeability | GitHub API and Ruby | An allowlisted profile, PR title, and base/head commits. A blocked PR receives a status comment and stops here. |
| Check out the head and compare it with the merge base | Git | `pr.diff`, with checkout credentials removed before AI runs. |
| Inspect dependency changes | Ruby in `lib/test_plan/dependency_delta/` | A dependency manifest, bounded source diff, and usage evidence. Full deltas and private kit facts stay outside the AI-readable workspace. |
| Choose the plan shape and prompt | `Profile.select_prompt` | Standard, dependency, or Playbook plan name and its allowlisted prompt path, based on dependency evidence. |
| Draft the plan | Cursor through `ai/providers/cursor.sh` | Untrusted text in `test-plan-agent.json`. **This is the only model call.** |
| Validate and render | `lib/test_plan/response/`, then `lib/test_plan/output/` | Parsed plan fields, then escaped Markdown. The selected parser and formatter follow the chosen plan shape. |
| Publish | Ruby in `lib/test_plan/pull_request/` | One authoritative pull request comment and diagnostic artifacts. |

The provider receives evidence assembled by Git and Ruby. Its response is parsed against a fixed shape; the formatters build the Markdown and escape untrusted text before GitHub publishes it. See the [test-plan guide](test-plans/README.md) for the action inputs, safeguards, and local test commands.
