# Yarn Package workflow

For each node version it will:

1. Setup node;
2. Install dependencies with `yarn`;
3. Run `yarn lint`;
4. Run `yarn build`;
5. Run `yarn test`;

When the workflow is run in `main`, and the commit is tagged with a tag starting with `v` and containing the package (see inputs) name, it will publish to npm (see secrets). Set `release-tag` to `false` to publish from any tag starting with `v`, such as the `v1.2.0` tags release-please creates. Tags starting with the package name and `-v`, such as the `my-package-v1.2.0` tags release-please creates in a repository with several packages, publish too.

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

| **Input**   | **Type** | **Required** | **Default**    |
| ----------- | -------- | ------------ | -------------- |
| package     | string   | true         |                |
| release-tag | boolean  | false        | true           |
| workdir     | string   | false        |                |
| node        | string   | false        | '["22"]'       |

## Secrets

The following secrets are expected to be available:

| **Secret** | **Required** |
| ---------- | ------------ |
| npm_token  | true         |
