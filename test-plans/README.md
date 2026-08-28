# Test Plans

Generates structured, non-technical manual QA plans from pull-request merge-base diffs. The shared action selects an allowlisted profile, optionally enriches the PR diff with raised public dependency source changes, and upserts one authoritative PR comment per profile.

## Profiles

| Profile | Model | Intended use |
| --- | --- | --- |
| `cobra-test-plan` | Cursor default | Standard CoBRA/Consent test plan. |
| `enhanced-cobra-test-plan` | `claude-opus-5[effort=high]` | Higher-effort CoBRA/Consent test plan. |

Both profiles use the same prompt, JSON schema, Markdown renderer, and dependency evidence. Their result, status, failure, and artifact namespaces are independent, so both can run against the same PR.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `profile` | yes | `cobra-test-plan` or `enhanced-cobra-test-plan`. |
| `app-id` | yes | GitHub App ID used to create an installation token. |
| `private-key` | yes | GitHub App private key. |
| `provider-api-key` | yes | Provider credential; Cursor maps it to `CURSOR_API_KEY`. |
| `pull-request-number` | yes | Pull request to analyze. |
| `provider` | no | Provider script name; default `cursor`. |
| `deepen-length` | no | Merge-base fetch increment; default `30`. |

Model selection belongs to the profile and cannot be overridden by a caller. The action deliberately has no additional-prompt input.

## Mergeability Gate

Before checkout or provider usage, the action asks GitHub whether the PR can be merged:

- Mergeable PRs continue normally.
- Conflicting PRs receive a profile-specific blocked comment telling the author to resolve conflicts and reapply the label.
- GitHub `UNKNOWN` responses are retried five times before a retry-later comment is posted.

A blocked run completes successfully, consumes no provider usage, and replaces that profile's previous plan so testers do not follow stale instructions.

## Dependency Evidence

The action detects raised Bundler and Yarn v1 dependencies across root and component lockfiles. Local CoBRA PATH components and Yarn workspace/file/link packages are excluded. Duplicate raises are collapsed across lockfiles.

For public sources, the action downloads old/new RubyGem or npm archives, or public GitHub revision archives, and creates a deterministic source diff without executing package contents. Retrieval is allowlisted to public HTTPS hosts and enforces archive traversal, link, file-count, expanded-size, download-size, and timeout controls.

Artifacts include:

- `test-plan-agent.json`
- `dependency-delta-manifest.json`
- `dependency-deltas-full.diff` (maximum 10 MiB)
- `dependency-deltas-context.diff` (maximum 100 KiB per dependency and 500 KiB total)

Missing private sources, failed downloads, and truncation do not fail the plan. They produce a warning in the PR comment, workflow annotation, job summary, and dependency manifest.

## Caller Workflow

Test plans are activated only through labels. A consumer workflow should map each supported label directly to the matching profile and pin this action to an immutable commit SHA.

```yaml
name: Test Plan

on:
  pull_request:
    types: [labeled]

permissions:
  contents: read
  pull-requests: write

jobs:
  test-plan:
    if: |
      github.event.pull_request.state == 'open' &&
      (
        github.event.label.name == 'cobra-test-plan' ||
        github.event.label.name == 'enhanced-cobra-test-plan'
      )
    runs-on: ubuntu-latest
    concurrency:
      group: test-plan-${{ github.event.pull_request.number }}-${{ github.event.label.name }}
      cancel-in-progress: false
    steps:
      - uses: powerhome/github-actions-workflows/test-plans@<pinned-commit-sha>
        with:
          profile: ${{ github.event.label.name }}
          app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
          private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
          provider: cursor
          provider-api-key: ${{ secrets.TEST_PLAN_PROVIDER_API_KEY }}
          pull-request-number: ${{ github.event.pull_request.number }}
```

Do not add `issue_comment` triggers or pass PR comment bodies to the action.

## Local Tests

Run every standalone Ruby spec:

```bash
for spec in test-plans/scripts/*_spec.rb; do
  ruby "$spec"
done
```
