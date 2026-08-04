# Agentic Acceptance Criteria Plan

## Summary

Create a reusable `agentic-acceptance-criteria` composite action that turns a pull request's merge-base diff into a structured, non-technical manual QA plan. The action will post one updatable comment on the PR and will use the same GitHub App credentials and Cursor provider pool as `agentic-pr-review`.

The initial consumer will be `nitro-web`, using a separate workflow that runs only when:

- The `agentic-acceptance-criteria` label is applied.
- A new PR comment begins with `/agentic-acceptance-criteria`.

It will never run automatically when a PR is opened, marked ready for review, or updated with new commits. Its comment command will not trigger the existing code-review workflow.

## Reusable Action

Add a self-contained `agentic-acceptance-criteria/` action alongside `agentic-pr-review/`.

The public inputs will match the review action:

| Input | Required | Purpose |
| --- | --- | --- |
| `app-id` | yes | Existing agentic-review GitHub App ID. |
| `private-key` | yes | Existing GitHub App private key. |
| `provider-api-key` | yes | Existing Cursor pool/API credential. |
| `pull-request-number` | yes | PR to analyze and comment on. |
| `provider` | no | Provider implementation; default `cursor`. |
| `deepen-length` | no | Merge-base history fetch increment; default `30`. |
| `model` | no | Optional provider model override. |
| `additional-prompt` | no | Full slash-command comment used as explicit generation guidance. |

The action will:

1. Create a short-lived installation token from the existing GitHub App secrets.
2. Post a temporary, tagged “acceptance criteria in progress” comment.
3. Fetch the current base and head SHAs for the PR.
4. Check out the PR head and fetch through its merge base.
5. Write the three-dot merge-base diff to `pr.diff`.
6. Run Cursor with read-only repository permissions.
7. Parse and validate Cursor's structured JSON response.
8. Render the deterministic Markdown QA format described below.
9. Upload the raw JSON as `agentic-acceptance-criteria-json`.
10. Upsert one tagged acceptance-criteria PR comment.

The PR title may be fetched for deterministic display in the comment heading, but it and the PR description will not be included in Cursor's generation context. Generated content will come only from `pr.diff`, read-only repository context, and optional slash-command instructions.

## Generation Contract

The prompt will instruct Cursor to:

- Write for non-technical manual QA testers.
- Cover all changed application behavior and plausible adjacent regressions.
- Identify roles and UI-facing permission Subject/Action pairs, along with validation paths, error behavior, state transitions, and differing access configurations, only when supported by the diff or repository.
- In Consent applications, resolve the matching action with `Consent.find_action(subject_key, action_key)`, use `action.subject.label` for the Subject, and titleize the action key for the Action. Do not use the Ruby class constant or Consent's descriptive action label.
- Call out permission definitions and direct permission lookups/checks added, removed, or modified by the diff.
- Inventory every distinctly affected reachable page before adding depth; each page whose changed behavior is not uniform with the others must have functional coverage.
- Group scenarios primarily by behaviorally uniform tester paths and secondarily by product domain.
- Include the landing-page relative URL and applicable Subject/Action pairs on every functional case.
- Mark functional cases that also provide regression coverage so Regression Testing can reference only their generated identifiers.
- Express each scenario as executable tester actions followed by observable `Verify...` outcomes.
- Avoid implementation details, code terminology, filenames, classes, migrations, and automated-test instructions.
- Avoid inventing application behavior or access requirements.
- Return “not identified” states when evidence is insufficient.
- Return strict JSON without Markdown fences or surrounding prose.

The response schema will be:

```json
{
  "permissions": {
    "required": "yes | no | not_identified",
    "roles": ["Role or access configuration"],
    "changes": [
      "Added permission lookup: Reminder Calls — Read."
    ],
    "subject_actions": [
      {
        "subject": "Reminder Calls",
        "action": "Read"
      }
    ]
  },
  "feature_areas": [
    {
      "test_path": "View and filter reminder call history",
      "domain": "Contact Center",
      "code": "RCH",
      "scenarios": [
        {
          "title": "Page load/default results",
          "landing_page": "/contact_center/reminder_calls",
          "permissions": [
            {
              "subject": "Reminder Calls",
              "action": "Read"
            }
          ],
          "include_in_regression": true,
          "steps": [
            "Open the feature.",
            "Verify the page loads and displays the expected default results."
          ]
        }
      ]
    }
  ],
  "regression_tests": [
    {
      "text": "Verify existing related behavior remains unchanged.",
      "details": ["Optional supporting check"]
    }
  ]
}
```

The parser and formatter will:

- Recover valid JSON when Cursor incorrectly adds prose or code fences.
- Require the documented root object and arrays.
- Normalize whitespace and discard empty entries.
- Deduplicate identical roles, permission-change notes, Subject/Action pairs, steps, and regression checks while retaining their original order.
- Validate feature codes as short uppercase identifiers; use `AC` when a supplied code is absent or invalid.
- Assign scenario numbers deterministically in output order, such as `RCH-1` and `RCH-2`.
- List generated identifiers for functional cases that also apply to Regression Testing without duplicating their full text.
- Render an explicit no-QA result when no feature scenarios or regressions are found.

## Generated PR Comment

Only the example beginning at line 68 (`✅ Test Plan`) informs this format. The preceding system story, launch plan, and original acceptance-criteria prose are excluded.

```markdown
## ✅ Test Plan: <PR title>

---

## Permissions / Roles

- **Required Permissions:** <Yes, No, or Not identified>
- **Permission Changes in This PR:**
  - <Added, removed, or modified permission definition or direct lookup/check>
- **Roles to Test:**
  - <Role, permission set, or access configuration>
  - <Additional role when behavior varies by access>
- **Permission Subjects / Actions:**
  - <UI Subject label> — <titleized UI Action>

---

## Functional / Features to Test

### <Shared tester path> — <secondary product domain, when identifiable>

#### <AREA>-1 — <Scenario name>

**Landing Page:** /<relative URL>
**Permissions:** <UI Subject label> — <titleized UI Action>; <additional permission when needed>

- <Setup or action written for a non-technical tester>
- <Next action>
- Verify <observable result>.
- Verify <relevant error, boundary, or alternate outcome>.

#### <AREA>-2 — <Scenario name>

**Landing Page:** /<relative URL>
**Permissions:** <No special permission required or not identified>

- <Setup or action>
- Verify <observable result>.

---

## Regression Testing

- **Applicable Functional Cases:** <AREA>-1, <AREA>-2

- Verify <existing related behavior remains unchanged>.
- Verify <neighboring workflow or page still works>.
- Verify <authorization or data visibility remains correct>.
  - <Optional detail>
```

All three sections will remain present and in this order. When no manual application QA is identified, the functional section will contain:

```markdown
- No manual application QA was identified for this change.
```

The successful result will use the `agentic-acceptance-criteria` comment tag so every rerun updates one authoritative comment. A separate tagged failure comment will preserve the previous successful plan, link to the failed workflow run, and be removed after the next successful run.

## `nitro-web` Trigger Workflow

Add a dedicated `.github/workflows/agentic-acceptance-criteria.yml` in `nitro-web`. Do not add the acceptance-criteria job to the existing review workflow.

The workflow will listen only for:

```yaml
on:
  pull_request:
    types: [labeled]
  issue_comment:
    types: [created]
```

Its job-level gate will require either:

- A `pull_request/labeled` event where the newly applied label is exactly `agentic-acceptance-criteria`.
- An `issue_comment/created` event attached to a PR where the body begins with `/agentic-acceptance-criteria`.

Additional behavior:

- Require the PR to be open.
- Allow any commenter with access to the private repository, matching the current review workflow.
- Pass the complete slash-command comment through `additional-prompt`.
- Use the existing `AGENTIC_REVIEW_GITHUB_APP_ID`, `AGENTIC_REVIEW_GITHUB_APP_PRIVATE_KEY`, and `AGENTIC_REVIEW_PROVIDER_API_KEY` secrets.
- Grant only `contents: read` and `pull-requests: write`.
- Use a PR-specific acceptance-criteria concurrency group with `cancel-in-progress: true`; a newer request supersedes an older in-progress generation.
- Do not consult or share the `agentic-review-opt-out` label because acceptance-criteria generation is explicitly invoked rather than automatic.
- Do not alter the existing `@nitro-pr-review` trigger. The slash command contains no review-bot mention and therefore triggers only acceptance criteria.

## Rollout

This requires two PRs, merged in order:

1. Merge the reusable action into `github-actions-workflows`.
2. Copy the resulting immutable commit SHA from `main`.
3. Open the `nitro-web` PR adding its dedicated workflow and pin `uses:` to that SHA.
4. Create the `agentic-acceptance-criteria` repository label if it does not already exist.
5. After the workflow exists on `nitro-web`'s default branch, validate it on a separate open PR.

Merging the shared action first is the safest sequence. It prevents `nitro-web` from depending on an unmerged branch and ensures later shared-action changes cannot silently alter the pinned consumer.

## Tests and Acceptance

### Reusable action tests

- Parse valid structured output.
- Recover JSON from fenced or prefixed output.
- Reject malformed roots and invalid field types.
- Normalize and deduplicate roles, permission-change notes, Subject/Action pairs, steps, and regression checks.
- Generate fallback `AC` scenario identifiers.
- Render the exact Markdown hierarchy, landing-page URLs, per-case permissions, and numbering.
- Render permission-change callouts and ensure every distinctly affected reachable page is represented.
- Reference regression-applicable functional identifiers without repeating their full scenarios.
- Render the explicit no-manual-QA result.
- Preserve the last successful comment when generation or parsing fails.

### Workflow validation

- Applying `agentic-acceptance-criteria` to an open PR runs only the acceptance-criteria action.
- `/agentic-acceptance-criteria` runs only the acceptance-criteria action.
- Text after the slash command reaches Cursor as additional guidance.
- `@nitro-pr-review` continues to run only code review.
- Opening a PR, marking it ready, and pushing commits do not trigger acceptance criteria.
- Ordinary comments, comments on issues, and triggers against closed PRs are ignored.
- Repeated runs update one comment instead of adding duplicate QA plans.
- A newer trigger cancels an older acceptance-criteria run for the same PR.
- The GitHub App authors the progress, result, and failure comments.

Run the standalone Ruby specs, validate the action and workflow YAML, and complete one label-triggered and one slash-command smoke test in `nitro-web`.
