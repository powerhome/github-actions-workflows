# Test Plans

The `test-plans` composite action generates structured, non-technical manual QA plans from pull-request merge-base diffs.

It provides one CoBRA/Consent profile:

- `cobra-test-plan`, using Cursor's default model.

The profile is activated by its matching pull-request label. Before invoking the provider, the action blocks generation for pull requests with merge conflicts. It also detects raised public Bundler and Yarn v1 dependencies and provides a bounded source delta to the model when one is available.

See the repository's [`test-plans/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/test-plans/README.md) for the complete action interface, caller example, dependency safeguards, and local test command.
