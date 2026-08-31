# Test Plans

The `test-plans` composite action generates structured, non-technical manual QA plans from pull-request merge-base diffs.

It currently provides two CoBRA/Consent profiles:

- `cobra-test-plan`, using Cursor's default model.
- `enhanced-cobra-test-plan`, using `claude-opus-5-high`.

Both profiles are activated exclusively by matching pull-request labels and maintain independent comments and artifacts. Before invoking the provider, the action blocks generation for pull requests with merge conflicts. It also detects raised public Bundler and Yarn v1 dependencies and provides a bounded source delta to the model when one is available.

See the repository's [`test-plans/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/test-plans/README.md) for the complete action interface, caller example, dependency safeguards, and local test command.
