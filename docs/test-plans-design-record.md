# Test Plan System Overhaul

## Summary

Replace `agentic-acceptance-criteria` with a scalable, profile-driven `test-plans` action. The first profiles will be:

- `cobra-test-plan`: the current CoBRA/Consent behavior, using Cursor's default model.
- `enhanced-cobra-test-plan`: the same prompt, schema, and Markdown format, pinned to `claude-opus-5[effort=high]`.

Initially deploy both profiles only to `nitro-web`. Test plans will be label-triggered exclusively. The action will continue to publish generated PR comments, but it will no longer accept comment commands or user-supplied prompt text.

Both profiles will also enrich the PR delta with source changes from raised public external dependencies. If a PR has merge conflicts, generation will stop before checkout or provider invocation and the profile's authoritative comment will explain how to unblock it.

## Shared Action and Profiles

Create one shared engine at `test-plans/action.yml` with an allowlisted `profile` input. Centralize provider execution, PR metadata, merge-base handling, dependency preprocessing, parsing, rendering, artifact upload, and comment lifecycle behavior in that action.

Store profile definitions under `test-plans/profiles/`. Each definition will provide:

- Profile identifier and display name.
- Prompt path.
- Model selection.
- Artifact namespace.
- Status, result, and failure comment tags.

The initial model settings will be:

- `cobra-test-plan`: omit `--model`, preserving the current Cursor-default behavior.
- `enhanced-cobra-test-plan`: pass `--model 'claude-opus-5[effort=high]'`.

Both profiles will use the same CoBRA/Consent prompt and strict JSON/Markdown output contract. Their only intentional generation difference will be model selection.

Give each profile independent status, result, failure, and artifact tags so both can run on the same PR without overwriting one another. Use the same Markdown template with profile-specific headings, such as `Cobra Test Plan` and `Enhanced Cobra Test Plan`.

Preserve the current behavior for:

- GitHub App authentication.
- Merge-base PR diffs.
- Read-only Cursor access.
- Strict JSON parsing and recovery.
- Deterministic Markdown rendering.
- Progress comments.
- Failure handling that preserves the previous successful plan.
- Raw JSON debugging artifacts.

Remove the old `agentic-acceptance-criteria/` implementation after its behavior and tests have migrated. Consumers pinned to an earlier immutable SHA remain valid until their workflows are changed.

### Public Action Interface

The shared action will accept:

| Input | Required | Purpose |
| --- | --- | --- |
| `profile` | yes | Allowlisted profile identifier, initially `cobra-test-plan` or `enhanced-cobra-test-plan`. |
| `app-id` | yes | GitHub App ID used to create the installation token. |
| `private-key` | yes | GitHub App private key. |
| `provider-api-key` | yes | Credential for the selected test-plan provider. |
| `pull-request-number` | yes | Pull request to inspect and comment on. |
| `provider` | no | Provider implementation; default `cursor`. |
| `deepen-length` | no | Merge-base fetch increment; default `30`. |

Unknown profiles must fail before posting progress or invoking a provider. Remove the public `additional-prompt` and caller-controlled `model` inputs so labels and profile definitions fully determine behavior.

## Merge-Conflict Preflight

Run a profile-aware mergeability gate before posting an in-progress comment, checking out code, computing diffs, retrieving dependencies, or invoking Cursor.

Query the pull request's GraphQL `mergeable` state together with its base/head SHAs and title. Handle GitHub's states as follows:

- `MERGEABLE`: continue with normal generation.
- `CONFLICTING`: stop generation and publish a blocked message.
- `UNKNOWN`: retry five times at two-second intervals because GitHub may still be calculating mergeability.

If mergeability remains `UNKNOWN`, stop without provider usage and publish a distinct message explaining that mergeability could not be determined and the label should be retried.

For `CONFLICTING`, upsert the affected profile's authoritative result comment with a message in this form:

```markdown
## ⚠️ Cobra Test Plan unavailable

This PR currently has merge conflicts with its base branch. Resolve the conflicts, then remove and reapply the `cobra-test-plan` label to generate a new test plan.

[View workflow run](<workflow-run-url>)
```

The enhanced profile will use its own display name and label in the same template.

Conflict handling will:

- Make no Cursor/provider call and consume no provider usage.
- Skip checkout, PR diff creation, and dependency retrieval.
- Replace a previously generated profile comment with the blocked message so testers do not follow a stale plan.
- Add the same explanation to the GitHub Actions job summary.
- Complete successfully because a merge conflict is an expected PR state rather than an infrastructure failure.
- Replace the blocked message with a newly generated plan after conflicts are resolved and the matching label is removed and reapplied.

## External Dependency Delta Enrichment

Add a preprocessing step after `pr.diff` is created. It will compare dependency manifests and lockfiles between the base and head revisions across the root application and component workspaces.

The first release will support:

- Bundler manifests and lockfiles.
- `package.json` and Yarn v1 lockfiles.

Treat registry packages and Git dependencies outside local CoBRA components as external. Exclude:

- Bundler `PATH` sources rooted under `components`.
- Yarn workspaces.
- `file:` and `link:` dependencies.

Detect semantic version increases and Git revision/ref changes. Include direct and transitive upgrades, but deduplicate identical package/version pairs repeated across component lockfiles.

### Public Source Retrieval

Retrieve evidence only from public sources in the initial implementation:

- Download and safely unpack exact old/new RubyGem and npm package archives.
- Compare old/new revisions for public Git dependencies.
- When Ruby and JavaScript packages resolve to the same public repository and version range, group them into one source comparison where possible to avoid duplicate context, particularly for Playbook upgrades.

Never execute downloaded package contents. Restrict retrieval to HTTPS, validate archive paths and symlinks, enforce download and extraction timeouts, and keep temporary content outside the checked-out repository.

Produce three outputs:

1. A machine-readable manifest listing every detected upgrade, whether it is direct or transitive, its source, retrieval status, and any warning.
2. A complete retrieved delta artifact capped at 10 MiB.
3. A provider-context delta capped at 100 KiB per dependency and 500 KiB total.

Prioritize context in this order:

1. Direct dependencies.
2. Git-pinned dependencies.
3. Transitive dependencies.

Within each dependency, prioritize changelogs and release notes, runtime source, tests, documentation, and generated/vendor files in that order. Truncate only at file-diff boundaries and record every omission in the manifest.

Continue generation when retrieval fails or is truncated. In that case:

- Add a concise warning beneath the generated plan heading.
- Emit a GitHub Actions warning.
- Add full details to the job summary.
- Upload the dependency manifest and available delta artifacts.

### Prompt Changes

Update the shared CoBRA prompt to:

- Treat `pr.diff` as the primary scope of the PR.
- Read the dependency manifest and bounded dependency delta when present.
- Correlate relevant external dependency behavior changes with the application changes.
- Add functional or regression coverage only when supported by the combined evidence.
- Avoid inventing effects from unrelated dependency internals.
- Keep dependency filenames, implementation details, and source terminology out of the rendered manual test plan.

### Deferred Private-Source Options

Private sources are intentionally deferred from the initial release.

Possible follow-up approaches are:

- **Owner-scoped token from the existing GitHub App:** quickest to implement and can be restricted to `contents: read`, but the token can read every repository included in that installation.
- **Dedicated dependency-reader GitHub App:** provides tighter repository-level access, but requires separate app installation, credentials, and maintenance.
- **Read-only `npm.powerapp.cloud` token:** enables exact private package archive retrieval, but introduces another secret, permission boundary, and rotation requirement.

Until a private-source approach is selected, private Git or registry dependencies will produce the visible warning and generation will continue. Public Playbook packages and repositories remain covered.

## Nitro Workflow and Rollout

1. Merge the shared engine, profile definitions, mergeability gate, and dependency preprocessing into `github-actions-workflows`.
2. Create a Nitro GitHub Actions secret named `TEST_PLAN_PROVIDER_API_KEY` containing the new Cursor key.
3. Continue using the existing GitHub App ID and private-key secrets. Do not change `agentic-pr-review` or its provider API key.
4. Replace Nitro's current workflow with a label-only `pull_request: [labeled]` workflow:
   - `cobra-test-plan` maps to the standard profile.
   - `enhanced-cobra-test-plan` maps to the enhanced profile.
   - Remove `issue_comment` entirely.
   - Pass no comment body or additional instructions.
   - Use profile-specific PR concurrency groups so the two variants do not block or overwrite one another.
5. Pin Nitro to the resulting immutable shared-repository commit SHA.
6. Create both new labels with descriptions explaining their model and cost distinction.
7. Smoke-test both profiles, then delete the old `agentic-acceptance-criteria` label. Leave historical comments untouched unless a new profile run replaces its own authoritative comment.
8. Do not deploy the pair to Tempo or the five non-CoBRA repositories in this rollout. Existing pending legacy workflow PRs should be closed or revised later because they use the obsolete generic/comment-trigger design.

## Tests and Acceptance

### Shared Engine and Output

- Preserve and relocate all existing parser, formatter, rendering, permission-resolution, no-manual-QA, and comment-lifecycle specs.
- Resolve both valid profiles and reject unknown or path-traversal profile values.
- Verify the standard profile omits `--model`.
- Verify the enhanced profile passes exactly `claude-opus-5[effort=high]`.
- Verify the two profiles use independent comment and artifact namespaces.
- Verify there is no `additional-prompt` input or comment-text prompt path.
- Confirm both variants retain the same JSON schema and Markdown hierarchy.

### Mergeability

- `MERGEABLE` proceeds through the normal generation pipeline.
- `CONFLICTING` skips checkout, diff construction, dependency retrieval, and provider invocation.
- `UNKNOWN` retries and proceeds if GitHub later reports `MERGEABLE`.
- Persistent `UNKNOWN` posts the distinct retry message and makes no provider call.
- Standard and enhanced conflict runs update only their respective authoritative comments.
- A conflict message replaces a previous plan for that profile.
- A successful rerun replaces the conflict message with the new plan.
- Conflict handling completes successfully and records the reason in the job summary.

### Dependency Detection and Retrieval

- Detect direct and transitive Bundler upgrades.
- Detect direct and transitive Yarn v1 upgrades.
- Deduplicate upgrades repeated across component lockfiles.
- Exclude local Bundler PATH components and Yarn workspaces/file/link dependencies.
- Ignore version decreases and removals as dependency raises.
- Detect changed Git revisions even when the package version is unchanged.
- Retrieve public RubyGem, npm, and Git fixtures successfully.
- Continue with warnings for private, missing, timed-out, or malformed sources.
- Reject path traversal, unsafe symlinks, oversized archives, and other unsafe extraction inputs.
- Apply deterministic prioritization and file-boundary truncation.
- Include dependency context only when a qualifying raise is detected.

### Nitro Smoke Tests

- Applying `cobra-test-plan` runs only the standard profile.
- Applying `enhanced-cobra-test-plan` runs only the enhanced profile.
- Applying both produces two independent, updatable comments.
- Enhanced logs confirm `claude-opus-5[effort=high]`.
- A public Playbook upgrade retrieves and uses its version delta.
- Missing, private, or truncated deltas visibly warn but still produce a plan.
- A conflicted PR produces the blocked message and consumes no provider usage.
- Resolving the conflict and reapplying the label replaces the blocked message with a plan.
- Ordinary PR comments and the former slash command trigger nothing.
- The new key's usage appears in the test-plan Cursor bucket, while Nitro PR review usage remains on its existing key.
- Repeated runs update only the matching profile comment.
- Provider or parsing failures preserve the previous successful plan.

## Assumptions

- Generated PR comments remain required; only user-authored comment triggers and prompt injection are removed.
- Both profiles receive the dependency-aware prompt enhancement.
- `claude-opus-5[effort=high]` is enabled for the Cursor account associated with the new key.
- External means anything not supplied by the local CoBRA `components` workspace, including transitive packages.
- Initial dependency retrieval is limited to public sources.
- The new provider key is stored only as a GitHub Actions secret and is shared by the two test-plan profiles, separate from `nitro-pr-review`.
- Conflict resolution does not trigger generation automatically; the user must remove and reapply the desired label.
