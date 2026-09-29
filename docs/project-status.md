# Project Status workflow

Adds a repository's issues and pull requests to an organization project (Projects V2) and keeps their Status field in step with their state:

| Item | Status |
| --- | --- |
| Open issue | none, waiting for triage |
| Closed issue | Done |
| Draft pull request | In progress |
| Pull request ready for review | In review |
| Pull request whose latest review requests changes, until review is requested again or it is approved | In progress |
| Closed or merged pull request | Done |

Dependabot pull requests are skipped, because they cannot read Actions secrets.

Events only trigger a run. Each run works the Status out from the issue or pull request as it is at that moment, including its review history, so runs that start late or out of order still leave the right Status. Runs for the same item also queue behind each other.

## Installation 🛠

The workflow writes to the project with a GitHub App, because the default `GITHUB_TOKEN` cannot write to organization projects. Install an App on the organization with **Organization projects: Read and write**, **Issues: Read** and **Pull requests: Read**, and make its client ID and private key available to the calling repositories.

Create a workflow file similar to this. The triggers are the caller's: a reusable workflow only sees the events its caller subscribes to.

```yml
name: Project status

on:
  issues:
    types: [opened, reopened, closed]
  pull_request:
    types: [opened, reopened, ready_for_review, review_requested, converted_to_draft, closed]
  pull_request_review:
    types: [submitted]

permissions: {}

jobs:
  project:
    uses: powerhome/github-actions-workflows/.github/workflows/project-status.yml@main
    with:
      project-owner: powerhome
      project-number: 18
      client-id: ${{ vars.GH_PROJECT_APP_CLIENT_ID }}
    secrets:
      private-key: ${{ secrets.GH_PROJECT_APP_PRIVATE_KEY }}
```

Turn off the project's built-in workflows that set Status (Item added, Item closed, Pull request merged and the like), so that this workflow is the only thing moving items.

## Inputs

| **Input** | **Type** | **Required** | **Default** |
| --- | --- | --- | --- |
| project-owner | string | true | |
| project-number | number | true | |
| client-id | string | true | |
| skip-label | string | false | |
| status-in-progress | string | false | In progress |
| status-in-review | string | false | In review |
| status-done | string | false | Done |

Issues and pull requests carrying `skip-label` are not added, for example Renovate's Dependency Dashboard. The `status-*` inputs name the Status options, if the project's differ from the defaults.

## Secrets

| **Secret** | **Required** |
| --- | --- |
| private-key | true |
