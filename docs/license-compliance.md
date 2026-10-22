# License Compliance

Validade the liceses included in a project following the allowed licenses in [Power's OSS Guide](https://github.com/powerhome/oss-guide).

## Installation 🛠

This workflow is included by the [Ruby](./ruby-gem.md) and [Yarn](./yarn-package.md) workflows. To include it manually:

```yml
name: blorgh

on:
  push:

jobs:
  license-compliance:
    uses: powerhome/github-actions-workflows/.github/workflows/ruby-gem.yml@main
    with:
      workdir: "${{ inputs.workdir }}"
```

## Inputs

The first of the `gemfiles` (or the `Gemfile`) is installed with the bundler cache of `ruby/setup-ruby`, which is shared with any build using the same `ruby` and gemfile. The other gemfiles are installed without a cache.

| **Input** | **Type** | **Required** | **Default**                  |
| --------- | -------- | ------------ | ---------------------------- |
| workdir   | string   | false        |                              |
| ruby      | string   | false        | 3.4.11                       |
| gemfiles  | string   | false        |                              |
| decisions | string   | true         | doc/dependency_decisions.yml |
