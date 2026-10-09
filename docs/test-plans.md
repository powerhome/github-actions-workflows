# Test Plans

The `test-plans` composite action generates structured, non-technical manual QA plans from pull-request merge-base diffs.

It provides two profiles, both using Claude Sonnet 5.5 at high effort on Cursor (the default provider), or the Claude CLI's default model when `provider: claude` is set:

- `cobra-test-plan` for CoBRA applications, naming the Consent permissions each scenario needs.
- `test-plan` for any other application, naming the account each scenario signs in as.

Each profile is activated by its matching pull-request label. Before invoking the provider, the action blocks generation for pull requests with merge conflicts. It detects changed Bundler, Yarn v1, and npm dependencies, skipping lockfiles inside vendored code, and provides a bounded source delta when available. Playbook changes use a kit-focused plan, other dependency changes use a version-change and regression plan, and PRs without an in-scope change use the standard functional plan.

See the repository's [`test-plans/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/test-plans/README.md) for the complete action interface, caller example, dependency safeguards, and local test command.
