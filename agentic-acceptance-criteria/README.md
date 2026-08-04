# Agentic Acceptance Criteria

Generates a structured manual QA plan from a pull request's **merge-base diff** and upserts it as a single GitHub PR comment. The default provider is **Cursor** (`agent` CLI with `CURSOR_API_KEY`).

The generated plan is written for non-technical testers and contains:

- Permissions and roles to test, including the Subject/Action labels shown in the application UI and direct permission changes made by the PR.
- Test-path-oriented scenarios with landing-page relative URLs, per-case permissions, and coverage for every distinctly affected reachable page.
- Targeted regression testing that references applicable functional case identifiers.

## What it does

1. Creates an installation token for a GitHub App.
2. Loads the PR base/head SHAs and checks out the PR head.
3. Produces `pr.diff` from the base/head merge base.
4. Runs the configured provider with read-only repository permissions.
5. Parses the provider's JSON into deterministic Markdown.
6. Upserts one tagged PR comment, preserving the previous successful plan if a later run fails.

The raw `acceptance-criteria-agent.json` file is uploaded as an artifact for debugging.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `app-id` | yes | GitHub App ID used with `actions/create-github-app-token`. |
| `private-key` | yes | GitHub App private key (PEM). |
| `provider-api-key` | yes | Provider API key; Cursor maps this to `CURSOR_API_KEY`. |
| `pull-request-number` | yes | PR number to analyze. |
| `provider` | no | Provider resolved through `scripts/providers/<provider>.sh`; default `cursor`. |
| `deepen-length` | no | Merge-base fetch increment; default `30`. |
| `model` | no | Optional provider model override. |
| `additional-prompt` | no | Extra generation guidance, such as a slash-command comment. |

## Secrets and permissions

The calling workflow needs `contents: read` and `pull-requests: write`. The GitHub App installation token is used to read PR metadata and clone the target repository. PR comments use the calling workflow's `GITHUB_TOKEN` so action-authored comments do not trigger recursive `issue_comment` workflow runs.

The action can reuse the same secrets as `agentic-pr-review`:

- `AGENTIC_REVIEW_GITHUB_APP_ID`
- `AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY`
- `AGENTIC_REVIEW_PROVIDER_API_KEY`

## Example

```yaml
- uses: powerhome/github-actions-workflows/agentic-acceptance-criteria@<pinned-commit-sha>
  with:
    app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
    private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
    provider: cursor
    provider-api-key: ${{ secrets.AGENTIC_REVIEW_PROVIDER_API_KEY }}
    pull-request-number: ${{ github.event.pull_request.number || github.event.issue.number }}
    additional-prompt: ${{ github.event_name == 'issue_comment' && github.event.comment.body || '' }}
```

Consumers should pin the action to an immutable commit SHA.

## `nitro-web` caller workflow

After this action is merged, add a separate workflow to `nitro-web` and replace `<pinned-commit-sha>` with the resulting commit on `main`:

```yaml
name: Agentic Acceptance Criteria

on:
  pull_request:
    types: [labeled]
  issue_comment:
    types: [created]

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.event.issue.number || github.ref }}
  cancel-in-progress: false

jobs:
  acceptance-criteria:
    name: Acceptance Criteria
    if: |
      (
        github.event_name == 'pull_request' &&
        github.event.action == 'labeled' &&
        github.event.label.name == 'agentic-acceptance-criteria'
      ) ||
      (
        github.event_name == 'issue_comment' &&
        github.event.issue.pull_request &&
        (
          github.event.comment.body == '/agentic-acceptance-criteria' ||
          startsWith(github.event.comment.body, '/agentic-acceptance-criteria ')
        )
      )
    runs-on: ubuntu-latest
    steps:
      - name: Skip ineligible PRs
        id: skip_gate
        if: |
          (github.event.pull_request.state || github.event.issue.state) != 'open'
        run: |
          echo "skip=true" >> "${GITHUB_OUTPUT}"
          echo "Skipping acceptance-criteria generation because the PR is not open"

      - name: Generate acceptance criteria with Cursor
        timeout-minutes: 15
        if: steps.skip_gate.outputs.skip != 'true'
        uses: powerhome/github-actions-workflows/agentic-acceptance-criteria@<pinned-commit-sha>
        with:
          app-id: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_ID }}
          private-key: ${{ secrets.AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY }}
          provider: cursor
          provider-api-key: ${{ secrets.AGENTIC_REVIEW_PROVIDER_API_KEY }}
          pull-request-number: ${{ github.event.pull_request.number || github.event.issue.number }}
          additional-prompt: ${{ github.event_name == 'issue_comment' && github.event.comment.body || '' }}
```

This workflow does not listen for PR opening, ready-for-review, or synchronization events. A bare `/agentic-acceptance-criteria` command or the command followed by same-line instructions triggers only this action.

## Generation context

The provider receives `pr.diff`, read-only access to repository files for context, and `additional-prompt` when supplied. It inventories every distinctly affected reachable page before adding depth, groups only behaviorally uniform tester paths, and uses product domain as a secondary classification. It also calls out permission definitions and direct permission lookups/checks added or modified by the diff. In Consent applications, it resolves each permission through the matching action, emits `action.subject.label` as the Subject, and titleizes the action key as the UI does. The PR title is used only by the deterministic formatter's heading, and the PR title and description are not included in the provider prompt.

## Cursor permissions

`config/cli-config.json` allows `Read(**)` and denies `Shell(*)`, `Write(**)`, and `Mcp(*:*)`.
