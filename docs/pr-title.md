# PR title workflow

Checks that a pull request's title is a [Conventional Commit](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope)!: description [KEY-123]
```

Repositories squash-merge with the title as the commit subject, so the title is what ends up in the history and what release tooling reads. The types are `feat`, `fix`, `perf`, `revert`, `docs`, `style`, `refactor`, `test`, `build`, `ci` and `chore`. The scope is optional unless `require-scope` is set, `!` marks a breaking change, and a Runway key goes in square brackets at the end.

It wraps [`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request) and only reads the pull request, so it needs no secrets and runs on pull requests from forks.

## Installation 🛠

Create a workflow file similar to this. The triggers are the caller's: include `edited`, so that fixing a title re-runs the check without a new commit.

```yml
name: PR title

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  pull-requests: read

jobs:
  pr-title:
    uses: powerhome/github-actions-workflows/.github/workflows/pr-title.yml@main
```

To require the check, add `pr-title / Conventional Commit title` to the repository's ruleset as a required status check. The first part is the caller's job ID, so keep it `pr-title` for the name to match.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `require-scope` | `false` | Fail titles that have no scope. |
| `scopes` | `""` | Newline-separated scopes to allow. Any scope is allowed when empty. |
