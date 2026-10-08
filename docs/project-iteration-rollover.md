# Project Iteration Rollover workflow

GitHub Projects does not carry unfinished work over when an iteration ends. An item keeps its old iteration, so it drops out of every view filtered to `@current`. This workflow moves that work into the current iteration of an organization project (Projects V2).

On each run it moves every item that meets all of these:

- its iteration has ended;
- its Status is not the done option;
- its issue or pull request is still open (draft issues count as open).

Items move to the iteration that contains today. Items with no iteration, in the current or a future iteration, or already done are left alone. When today falls in a gap between iterations, nothing moves.

A run is idempotent, so a daily schedule is enough: the first run after an iteration ends moves its leftovers, and later runs find nothing to do.

## Installation 🛠

The workflow writes to the project with a GitHub App, because the default `GITHUB_TOKEN` cannot write to organization projects. It can share the App used by [project-status](project-status.md): **Organization projects: Read and write**, **Issues: Read** and **Pull requests: Read**.

The rollover is project-wide, so call it from one repository only, on a schedule:

```yml
name: Project iteration rollover

on:
  schedule:
    - cron: '0 5 * * *'
  workflow_dispatch:
    inputs:
      dry-run:
        description: List what would move without changing anything.
        type: boolean
        default: true

permissions: {}

jobs:
  rollover:
    uses: powerhome/github-actions-workflows/.github/workflows/project-iteration-rollover.yml@main
    with:
      project-owner: powerhome
      project-number: 18
      client-id: ${{ vars.GH_PROJECT_APP_CLIENT_ID }}
      iteration-field: Sprint
      dry-run: ${{ inputs.dry-run || false }}
    secrets:
      private-key: ${{ secrets.GH_PROJECT_APP_PRIVATE_KEY }}
```

## Inputs

| **Input** | **Type** | **Required** | **Default** |
| --- | --- | --- | --- |
| project-owner | string | true | |
| project-number | number | true | |
| client-id | string | true | |
| iteration-field | string | false | Iteration |
| status-done | string | false | Done |
| dry-run | boolean | false | false |

## Secrets

| **Secret** | **Required** |
| --- | --- |
| private-key | true |
