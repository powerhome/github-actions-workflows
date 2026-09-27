# Test Plans

Generates structured, non-technical manual QA plans from pull-request merge-base diffs. The action uses the `cobra-test-plan` profile, optionally enriches the PR diff with raised public dependency source changes, and upserts one authoritative PR comment.

## Profiles

| Profile | Model | Intended use |
| --- | --- | --- |
| `cobra-test-plan` | Cursor default | Standard CoBRA/Consent test plan. |

Each scenario names the audience it belongs to when an application serves more than one from different hostnames — where the umbrella routes mount two engines at the same prefix behind subdomain constraints, a relative path alone does not identify the page. Applications with no such constraint produce plans with no audience line.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `profile` | yes | `cobra-test-plan`. |
| `app-id` | yes | GitHub App ID used to create an installation token. |
| `private-key` | yes | GitHub App private key. |
| `provider-api-key` | yes | Provider credential; Cursor maps it to `CURSOR_API_KEY`. |
| `pull-request-number` | yes | Pull request to analyze. |
| `provider` | no | Provider script name; default `cursor`. |
| `deepen-length` | no | Merge-base fetch increment; default `30`. |

Cursor selects its default model. The action deliberately has no model or additional-prompt input.

## Mergeability Gate

Before checkout or provider usage, the action asks GitHub whether the PR can be merged:

- Mergeable PRs continue normally.
- Conflicting PRs receive a blocked comment telling the author to resolve conflicts and reapply the label.
- GitHub `UNKNOWN` responses are retried five times before a retry-later comment is posted.

A blocked run completes successfully, consumes no provider usage, and replaces that profile's previous plan so testers do not follow stale instructions.

## Dependency Evidence

The action detects raised Bundler and Yarn v1 dependencies across root and component lockfiles, comparing the merge base against the head so it sees the same range as `pr.diff`. Local CoBRA PATH components and Yarn workspace/file/link packages are excluded. Duplicate raises are collapsed across lockfiles.

By default, gem raises must reach the root `Gemfile.lock`, while raises in every changed `yarn.lock` are analyzed. Playbook is the exception: its raise is always analyzed, including when it appears only in a component `Gemfile.lock`. Nitro-web's `components/pulse-ui/yarn.lock` and `components/connect-web-ui/yarn.lock` are therefore in scope: their UI code is served by the application. Other component-only gem raises can resolve dependencies used only by component test suites and are skipped — on nitro-web, 15 of the 17 raises previously skipped were one component's test gems competing for the context budget against the Playbook raise. A gem raise recorded in both root and component lockfiles is kept, since deduplication runs first. Skipped gem raises are named in the manifest and job summary and raise no warning because they cost no evidence. Set `dependency-scope: all` to analyze component-only gem raises too. The setting governs gems only: every changed `yarn.lock` is analyzed under either value, so there is no way to narrow Yarn back to the root lockfile. That is deliberate — a component's UI code is served by the deployed application, where a component's test gems are not — but it means a repository whose component `yarn.lock` files resolve tooling rather than served code will see those raises analyzed. A dependency that moves between a Git source and a registry is reported as a source transition: the two sides are not comparable artifacts, so no delta is retrieved, but the change is named rather than dropped. A gem and an npm package published together as one upstream release — Playbook — are linked in the manifest and in the provider context, so the same change is not covered twice. The pairs are named explicitly rather than inferred from matching names and versions, because linking drops each half's build output and a wrong link would cost both of them their evidence. Both deltas are still retrieved, because the published gem and package differ.

Where a package records its repository, the action also reads that repository's `CHANGELOG.md` and diffs the upgraded-from tag against the default branch. Published packages routinely omit their changelog — neither the `playbook_ui` gem nor the `playbook-ui` tarball ships one — yet it is the highest-signal artifact available for a QA plan, naming behaviour changes in product terms rather than leaving them to be inferred from code. The upgraded-to tag decides how the pair is read. Where a project commits its changelog before tagging, that tag already describes the release and the two tags bracket the upgrade exactly. Where it is committed after tagging, that tag holds everything up to but not including its own release — which makes it the baseline, not the new side — and the default branch supplies the notes, along with anything released since, which the delta says. A Git-pinned dependency is read at its pinned revision, since the lockfile names exactly which commits are in use. Diffing rather than parsing keeps this working across changelog formats. A changelog also survives a package download the registry refuses, so a private package can still contribute its public release notes.

For public sources, the action downloads old/new RubyGem or npm archives, or public GitHub revision archives, and creates a deterministic source diff without executing package contents. Retrieval is allowlisted to public HTTPS hosts and enforces archive traversal, link, file-count, expanded-size, download-size, and timeout controls.

Context is prioritized across dependencies as direct, then Git-pinned, then transitive, then by how many lockfiles the dependency appears in — blast radius rather than the alphabet, so a gem in a hundred components is funded before one in a single component. Within each dependency the order is changelogs and release notes, runtime source, tests, documentation, and finally generated or vendored files. The 1 MiB context budget is shared out among the dependencies that changed rather than fixed per dependency, so a lone upgrade can use all of it and an upgrade that came in small hands its surplus to the next.

Playbook draws four times an ordinary dependency's slice because its kit changes can affect many application call sites. The packages are named in `Generator::WEIGHTED_PACKAGES` rather than inferred.

Where a gem and an npm package are linked as one upstream release, the build output in either half is kept out of the provider context — it is compiled from source that reaches the model through the other half — while non-generated files such as `package.json` still go through. Everything stays in the full-delta artifact regardless.

A binary file has no readable diff, so a change to one is recorded as a one-line marker rather than dropped — an icon, image, or font changing is user-visible even when its contents are not. Truncation happens only at file-diff boundaries, and the manifest names every file it dropped in `omitted_from_context`, `excluded_generated`, and `omitted_from_artifact`. An oversized changelog is capped for the provider only; the artifact keeps the whole diff.

A dependency is counted as a warning when the run lost evidence for it — it could not be retrieved, its provider context lost a changelog or source diff, or its source was refused and only the changelog survived. Build output deliberately kept out of a linked release, an artifact that ran out of room while the provider context did not, and a context budget that ran out after the changelog and source were in — dropping only tests and documentation off the tail — are expected and are not counted.

Artifacts include:

- `test-plan-agent.json`
- `dependency-delta-manifest.json`
- `dependency-deltas-full.diff` (maximum 10 MiB, written outside the workspace)
- `dependency-deltas-context.diff` (1 MiB in total, shared out among the dependencies that changed)
- `dependency-kit-usage.md`
- `dependency-usage.md` (bounded application source matches for raised package names)
- `playbook-kit-facts.json` (what the action worked out about each changed kit; written outside the workspace, like the full delta, because it carries the call-site counts the evidence withholds from the provider)

### Playbook Kit Usage

A Playbook version bump often changes no application code at all — every file in the diff is a lockfile — so `pr.diff` cannot say which pages to test. When the upgrade is Playbook, the action reads the changed kits from the gem's own diff paths (`app/pb_kits/playbook/pb_<kit>/`, which is exact, where matching release-note headings is guesswork) and searches the repository for where each is used, in Rails templates and React alike.

Documentation and tests inside a kit do not count as the kit changing. Playbook ships both in the kit directory, so a release that only refreshed a docs example used to report the kit as changed and send testers looking for a difference there was none of. The filter is `SourceDiff#evidence?`, the same classification the context budget already uses.

A kit is two implementations sharing a name, and a release usually moves only one. The changed side is derived from the extensions of the changed files — `.rb`/`.erb`/`.haml` is Rails, `.tsx`/`.jsx`/`.ts`/`.js` is React, a stylesheet or anything unrecognised is both — and only the changed side is searched for, so a Rails-only change stops paying for a React search. Rails and React call sites are listed separately, and a changed side nothing here renders is said rather than left as an empty list.

Call sites are spread across components before they are sampled. `git grep` answers in lexicographic order, which is the worst order to sample a monorepo in: `pb_body` matched 1106 files and the first twenty were every one of them under `components/accounting/`, so the "sample" covered one corner of the application while the plan called the kit covered. `CallSiteSample` round-robins by component first.

A kit whose usage search could not be completed says so rather than borrowing the representative-sample wording: "testing every use is not practical" is a claim about how widely the kit is used, and a search that did not finish supports no such claim. Publishing it would assert something unknown and bury the failure.

No counts appear in the evidence file or the comment. A kit with four call sites or fewer reads as "every use is listed"; more reads as a representative sample. The action decides that from its own search and carries it to the render step in `playbook-kit-facts.json` — written outside the workspace, since the provider reads the workspace with `Read(**)` and this is the one file whose numbers it must not see — so the provider is never asked to report a number nobody can check — it earlier reported a kit as used in 1083 files, and a count it copies is a count that can be wrong. The counts stay in that facts file, the job summary and the run log.

### Plan selection

After building the dependency delta, the action chooses one output shape. Any Playbook raise uses the Playbook plan, even if other dependencies were raised, no changed kit was found, or application code also changed. Otherwise, any in-scope dependency raise uses the dependency plan. A PR without an in-scope raise uses the standard functional plan. The selected prompt and parser/formatter always agree through the variant step output.

### The dependency plan

The dependency plan lists every in-scope version raise from the manifest. The provider adds a short product-facing note and version-specific steps only when the retrieved delta shows an observable change. If an upstream delta is unavailable or the provider omits an entry, the renderer still lists the version change with an evidence-aware fallback note.

Its Regression Testing section traces raised libraries to repository call sites and explains how a tester can exercise existing application behavior. A case naming a dependency this pull request did not raise is not testing the raise, so it is dropped — and named in the plan's discard notice, like every other omission. The action supplies a bounded `dependency-usage.md` with candidate source files, spread across components; a text match alone does not establish a route, so the provider must verify each case. The section has no functional-case references. When application code changes alongside a version raise, an optional Application Compatibility Checks section covers those edits without presenting the dependency upgrade as a new feature. The prompt reads `pr.diff`, the manifest, and the bounded dependency delta; it may inspect repository files needed to ground a usage path.

### The Playbook plan

The Playbook plan groups regression cases by changed, used kit. It reads the manifest, kit usage, upstream delta, and `pr.diff`. If no changed kit is identified, it still lists the Playbook version raise and can include regression cases for evidence-backed usage outside the kit report. If application code changes alongside Playbook, Application Compatibility Checks cover those edits.

Each kit case carries the page and whether it is a Rails or React call site. The plan has no permissions section for a pure version raise. A closing section lists other dependencies the pull request raised. Playbook's own version constant, packaging, and documentation site are not tester-facing changes.

Coverage wording is the action's, not the provider's. A kit with no matching fact reads as a sample, and a kit the action found exhaustible is downgraded to a sample anyway when the provider wrote fewer cases than there are call sites, because "every use is listed below" would then be false.

When changed kits are found, `dependency-kit-usage.md` lists which side changed and the call sites for that side. The manifest remains the authoritative list of in-scope raises; its separate `out_of_scope` list records skipped component-only gems.

Unreadable lockfiles, missing private sources, failed downloads, and truncation do not fail the plan. A lockfile the action cannot parse is skipped and reported; the remaining lockfiles are still analyzed. Every case that cost evidence produces a warning in the PR comment, workflow annotation, job summary, and dependency manifest; every omission is named in the manifest whether or not it counted. The comment and the annotation name the dependencies and why — `irb, minitest (provider context budget exhausted)` — grouping the dependencies that share a reason and pointing at the manifest for the file lists. The manifest is also echoed into the build step's log under a collapsed `Dependency delta manifest` group, so the reason a warning was raised is readable without downloading the artifact from an ephemeral runner.

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
- The workspace holds no credential while the provider runs. `actions/checkout` persists the installation token in `.git/config`, so it is removed once the last fetch is done — every later Git operation is local — rather than left where an agent with `Read(**)` could find it.
- The unbounded full delta is written outside the workspace and uploaded from there. Inside it, an agent could read it and bypass both the context budget and the generated-file exclusions.
- The Cursor CLI installer is downloaded before it is run, rather than piped into a shell, and the run logs its size and SHA-256. Piping starts executing while the transfer is still in flight, so an interrupted download leaves the first half already run with no record of what that was. The installer is still unpinned — Cursor documents no version-pinned CI install — so this bounds the failure mode rather than removing it.
- The provider runs read-only and offline. `config/cli-config.json` allows `Read(**)` and denies `Shell(*)`, `Write(**)`, `Mcp(*:*)`, `WebFetch(*)`, and `WebSearch(*)`, and is copied into the workspace after the quarantine so a pull-request copy cannot replace it. Everything a plan says has to come from evidence this action assembled.
- A part of the response the schema cannot use — a scenario with no steps, a feature area with no test path — is dropped rather than failing the run, since one unusable scenario should not cost an otherwise sound plan. The rendered plan says how many parts were dropped and why, so a partial plan is never mistaken for a complete one.
- Provider output is never trusted as Markdown. It is parsed against a fixed JSON schema and re-rendered by a deterministic formatter, so anything outside the schema is discarded rather than published. Every provider-derived field, and the pull-request title, is escaped before rendering: mentions cannot notify anyone, and links, images, and inline HTML cannot be injected into a comment the bot signs. Inline code is the single exception, so a plan can set a route or an identifier apart from the prose around it. A complete code span passes through as written — GitHub renders its contents literally, resolving no mention, autolinking no URL, and interpreting no tag — while a backtick that closes nothing is neutralised like any other markup, so a response cannot open a code block that swallows the plan below it.
- Cursor selects its default model. There is no caller-supplied prompt or model input, and no `issue_comment` trigger, so comment text never reaches the provider.
- Comments are authored with the calling workflow's `GITHUB_TOKEN` so action-authored comments do not retrigger workflows.
- Comments are posted, updated, and deleted through `gh` rather than a third-party action. Each is identified across runs by a marker in its own body (`<!-- powerhome/github-actions-workflows "<tag>" -->`), so one profile keeps one authoritative comment. A comment written by the action this replaced is still recognised and adopted on its next update.

Two residual risks are inherent rather than mitigated. Retrieved dependency source, including changelogs, is third-party text placed in the provider's context; it is supplied as evidence about a version change and the schema bounds what can come back, but it is not trusted input. And a pull request necessarily influences its own test plan through the code it changes — that is the feature. Treat a generated plan as a reviewed starting point, not an authority.

## Caller Workflow

Test plans are activated only through the `cobra-test-plan` label. A consumer workflow should pass that label as the profile and pin this action to an immutable commit SHA.

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
      github.event.label.name == 'cobra-test-plan'
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
ruby test-plans/spec/test_plan/dependency_delta/generator_spec.rb
```
