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

| **Input** | **Type** | **Required** | **Default**                  |
| --------- | -------- | ------------ | ---------------------------- |
| workdir   | string   | false        |                              |
| decisions | string   | true         | doc/dependency_decisions.yml |
