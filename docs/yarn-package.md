# Yarn Package workflow

For each node version it will:

1. Setup node;
2. Install dependencies with `yarn`;
3. Run `yarn lint`;
4. Run `yarn build`;
5. Run `yarn test`;

When the workflow is run in `main`, and the commit is tagged with a tag containing the package (see inputs) name, it will publish to npm (see secrets).

## Installation 🛠

Create a workflow file similar to this:

```yml
name: blorgh-react

on:
  push:

jobs:
  js:
    uses: powerhome/github-actions-workflows/.github/workflows/yarn-package.yml@main
    with:
      package: ${{ github.workflow }}
    secrets: inherit
```

## Inputs

| **Input** | **Type** | **Required** | **Default**    |
| --------- | -------- | ------------ | -------------- |
| workdir   | string   | false        |                |
| node      | string   | false        | '["18", "16"]' |

## Secrets

The following secrets are expected to be available:

| **Secret** | **Required** |
| ---------- | ------------ |
| npm_token  | true         |
