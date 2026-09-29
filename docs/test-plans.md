# Test Plans

The `test-plans` composite action generates structured, non-technical manual QA plans from pull-request merge-base diffs.

It provides one CoBRA/Consent profile:

- `cobra-test-plan`, using Cursor's default model.

The profile is activated by its matching pull-request label. Before invoking the provider, the action blocks generation for pull requests with merge conflicts. It detects raised Bundler and Yarn v1 dependencies and provides a bounded source delta when available. Playbook raises use a kit-focused plan, other dependency raises use a version-change and regression plan, and PRs without an in-scope raise use the standard functional plan.

The boundary is explicit in `action.yml`: Git and Ruby assemble evidence, one `AI: Generate test-plan JSON` step invokes Cursor from `test-plans/ai/`, and Ruby validates and renders the response before posting it. The three response parsers live in `test-plans/lib/test_plan/response/`; their matching Markdown formatters live in `test-plans/lib/test_plan/output/`. The [repository README](https://github.com/powerhome/github-actions-workflows/blob/main/README.md#how-test-plans-are-made) maps the information flow, and the [`test-plans/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/test-plans/README.md#information-flow-git-ai-and-publication) explains each stage.

See the repository's [`test-plans/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/test-plans/README.md) for the complete action interface, caller example, dependency safeguards, and local test command.
