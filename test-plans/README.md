# Test Plans

Generates structured, non-technical manual QA plans from pull-request merge-base diffs. The shared action selects an allowlisted profile, optionally enriches the PR diff with raised public dependency source changes, and upserts one authoritative PR comment per profile.

## Profiles

| Profile | Model | Intended use |
| --- | --- | --- |
| `cobra-test-plan` | Cursor default | Standard CoBRA/Consent test plan. |
| `enhanced-cobra-test-plan` | `claude-opus-5-high` | Higher-effort CoBRA/Consent test plan. |

Both profiles use the same prompt, JSON schema, Markdown renderer, and dependency evidence.

Each scenario names the audience it belongs to when an application serves more than one from different hostnames. Tempo's umbrella routes mount two engines at `/` behind subdomain constraints, so a relative path alone does not identify the page; nitro-web has no such constraint and its plans carry no audience line. Their result, status, failure, and artifact namespaces are independent, so both can run against the same PR.

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

The action detects raised Bundler and Yarn v1 dependencies across root and component lockfiles, comparing the merge base against the head so it sees the same range as `pr.diff`. Local CoBRA PATH components and Yarn workspace/file/link packages are excluded. Duplicate raises are collapsed across lockfiles. A gem and an npm package that move through identical versions together — Playbook, in practice — are linked as one upstream release in the manifest and in the provider context, so the same change is not covered twice. Both deltas are still retrieved, because the published gem and package differ.

Where a package records its repository, the action also reads that repository's `CHANGELOG.md` and diffs the upgraded-from tag against the default branch. Published packages routinely omit their changelog — neither the `playbook_ui` gem nor the `playbook-ui` tarball ships one — yet it is the highest-signal artifact available for a QA plan, naming behaviour changes in product terms rather than leaving them to be inferred from code. It is read at the default branch rather than the upgraded-to tag because a generated changelog is usually committed after its release is tagged. Diffing rather than parsing keeps this working across changelog formats. A changelog also survives a package download the registry refuses, so a private package can still contribute its public release notes.

For public sources, the action downloads old/new RubyGem or npm archives, or public GitHub revision archives, and creates a deterministic source diff without executing package contents. Retrieval is allowlisted to public HTTPS hosts and enforces archive traversal, link, file-count, expanded-size, download-size, and timeout controls.

Context is prioritized across dependencies as direct, then Git-pinned, then transitive; and within each dependency as changelogs and release notes, runtime source, tests, documentation, and finally generated or vendored files. The 500 KiB context budget is shared out among the dependencies that changed rather than fixed per dependency, so a lone upgrade can use all of it and an upgrade that came in small hands its surplus to the next.

Where a gem and an npm package are linked as one upstream release, the build output in either half is kept out of the provider context — it is compiled from source that reaches the model through the other half — while non-generated files such as `package.json` still go through. Everything stays in the full-delta artifact regardless.

Truncation happens only at file-diff boundaries, and the manifest names every file it dropped in `omitted_from_context`, `excluded_generated`, and `omitted_from_artifact`.

Artifacts include:

- `test-plan-agent.json`
- `dependency-delta-manifest.json`
- `dependency-deltas-full.diff` (maximum 10 MiB)
- `dependency-deltas-context.diff` (maximum 100 KiB per dependency and 500 KiB total)
- `dependency-kit-usage.md`

### Playbook Kit Usage

A Playbook version bump often changes no application code at all — nitro-web's 17.1.0 bump touched 143 files, every one a lockfile — so `pr.diff` cannot say which pages to test. When the upgrade is Playbook, the action reads the changed kits from the gem's own diff paths (`app/pb_kits/playbook/pb_<kit>/`, which is exact, where matching release-note headings is guesswork) and searches the repository for where each is used, in Rails templates and React alike.

The result is `dependency-kit-usage.md`, listing the files that use each changed kit. A kit used in more than 25 files is reported as a count instead, since a list that long stops naming pages to visit. On the real 17.0.0 → 17.1.0 upgrade this identifies 22 changed kits, six of them narrow enough to enumerate — including the two form inputs that release converted from React-rendered kits to enhanced elements.

Unreadable lockfiles, missing private sources, failed downloads, and truncation do not fail the plan. A lockfile the action cannot parse is skipped and reported; the remaining lockfiles are still analyzed. Every such case produces a warning in the PR comment, workflow annotation, job summary, and dependency manifest.

### Private Sources

A package is only fetched from a public registry when the lockfile shows it came from one. Gems must have resolved from `rubygems.org`. npm packages resolved from `registry.npmjs.org` or `registry.yarnpkg.com` are fetched directly; a package resolved through a private registry is fetched only when its lockfile `integrity` (or legacy sha1 fragment) matches the public package's, which keeps proxied public packages covered. Anything else is reported as a private source rather than guessed at, so a same-named private package never has unrelated public source fed to the provider.

Retrieving genuinely private sources is deferred. Three approaches were considered, none adopted yet:

- An owner-scoped token from the existing GitHub App. Quickest, and restrictable to `contents: read`, but the token can read every repository in that installation.
- A dedicated dependency-reader GitHub App. Tighter repository-level access, at the cost of a separate installation, credentials, and maintenance.
- A read-only `npm.powerapp.cloud` token. Enables exact private package retrieval, and adds another secret, permission boundary, and rotation requirement.

Until one is chosen, private dependencies warn and generation continues.

## Security Model

The pull-request head is untrusted: anyone who can open a pull request controls its contents. The action treats it that way.

- Agent-instruction paths are reset to the merge base before any provider runs: `.cursor/` directories at any depth, `.cursorrules`, `.cursorignore`, `.cursorindexingignore`, and `AGENTS.md`. Harness that made it through review still applies; a version the pull request edited is reverted, and one it introduced is removed. Without this a pull request could rewrite its own test plan, or edit `.cursorignore` to hide the code it changed from the reviewer.
- The provider runs read-only. `config/cli-config.json` allows `Read(**)` and denies `Shell(*)`, `Write(**)`, and `Mcp(*:*)`, and is copied into the workspace after the quarantine so a pull-request copy cannot replace it.
- Provider output is never trusted as Markdown. It is parsed against a fixed JSON schema and re-rendered by a deterministic formatter, so anything outside the schema is discarded rather than published.
- Model selection comes from the profile. There is no caller-supplied prompt or model input, and no `issue_comment` trigger, so comment text never reaches the provider.
- Comments are authored with the calling workflow's `GITHUB_TOKEN` so action-authored comments do not retrigger workflows.

Two residual risks are inherent rather than mitigated. Retrieved dependency source, including changelogs, is third-party text placed in the provider's context; it is supplied as evidence about a version change and the schema bounds what can come back, but it is not trusted input. And a pull request necessarily influences its own test plan through the code it changes — that is the feature. Treat a generated plan as a reviewed starting point, not an authority.

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

## Layout

```
test-plans/
  action.yml          composite action definition
  bin/                entry points the action steps invoke
  lib/test_plan/      library code, namespaced under TestPlan
  spec/               specs, mirroring lib/
  profiles/           allowlisted profile definitions
  prompts/            provider prompts
  providers/          per-provider shell adapters
  config/             provider CLI permissions
```

## Local Tests

Run the whole suite in one process:

```bash
ruby test-plans/spec/run_all.rb
```

A single file works the same way, since each spec loads the shared helper:

```bash
ruby test-plans/spec/test_plan/dependency_delta_spec.rb
```
