# Ruby Gem workflow

For each ruby version, bundler version, and Gemfile (see inputs), it will:

1. Setup ruby;
2. Run an optional before-build step (see inputs);
3. Run the build script (`bundle exec rake` default task);
4. Run the license_finder gem to ensure license compliance.

When the workflow is run in `main`, and the commit is tagged with a tag containing the package (see inputs) name, it will publish to Rubygems (see secrets).

## Installation 🛠

Create a workflow file similar to this:

```yml
name: blorgh

on:
  push:

jobs:
  ruby:
    uses: powerhome/github-actions-workflows/ruby-gem.yml
    with:
      package: ${{ github.workflow }}
      gemfiles: "['gemfiles/rails_6_0.gemfile','gemfiles/rails_6_1.gemfile','gemfiles/rails_7_0.gemfile']"
    secrets: inherit
```

## Inputs

| **Input**    | **Type** | **Required** | **Default**                 |
| ------------ | -------- | ------------ | --------------------------- |
| before_build | string   | false        |                             |
| package      | string   | true         |                             |
| workdir      | string   | false        |                             |
| ruby         | string   | false        | '["2.7","3.0","3.1","3.2"]' |
| gemfiles     | string   | false        | '["Gemfile"]'               |
| bundler      | string   | false        | '["2"]'                     |
| exclude      | string   | false        | "[]"                        |

## Secrets

The following secrets are expected to be available:

| **Secret**       | **Required** |
| ---------------- | ------------ |
| rubygems_api_key | true         |
