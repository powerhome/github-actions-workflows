# decision-records

Checks a repository's decision records against [RFC 0116](https://github.com/powerhome/rfcs/pull/240): architecture decision records (ADRs) in [MADR 4.0.0](https://adr.github.io/madr/) format, and change intent records (CIRs) in the format published on [blog.bryanl.dev](https://blog.bryanl.dev/posts/change-intent-records/). The [BT Handbook](https://github.com/powerhome/bt-handbook) documents the standard itself.

The checks are mechanical. Whether a record says something sensible is for review; whether its number is unique and its metadata and links are valid is checked here.

## What it checks

For every record directory:

- Each record is named `NNNN-title-with-dashes.md`, in lower case. `README.md`, `index.md` and the directory's template (`adr-template.md` or `cir-template.md`) are not records.
- No two records share a number. The error names the next number to renumber the later record to.
- The numbers run from `0001` with no gaps. A missing number is reported against the record after it, which is usually a record that took a number ahead of the default branch.

For ADRs:

- YAML front matter with only MADR's keys: `status`, `date`, `decision-makers`, `consulted` and `informed`.
- `status` is `proposed`, `accepted`, `rejected`, `deprecated` or `superseded by ADR-NNNN`, and a superseding ADR exists.
- `date` is `YYYY-MM-DD`.
- `decision-makers` is set on every ADR that is not `proposed`.
- The `#` title states the decision without a number.
- The MADR sections Context and Problem Statement, Considered Options and Decision Outcome are present. Headings may be in title or sentence case.

For CIRs:

- The title is `# CIR-NNNN: <what the change does>`, with the file's number.
- The sections Intent, Behavior, Constraints, Decisions and Date are present, and Date holds a `YYYY-MM-DD` date.
- Every `Supersedes: CIR-NNNN` line names a CIR that exists.

Where `mkdocs.yml` lists record pages one by one, every record in that directory must be listed. A nav that collects records by glob, or leaves them to a plugin, is not checked.

## Usage

Records are numbered from the default branch: a new record takes the highest number there, plus one. Open pull requests don't reserve numbers, so two can take the same one. The first to merge keeps it; the other merges the default branch in and renumbers its record, and this check fails it until it does.

A pull request's check only sees the default branch as it was when it ran, and doesn't run again when the default branch moves. Require branches to be up to date before merging, so the losing pull request has to merge the default branch in, which re-runs the check and fails on the duplicate before it lands. Also run the check on pushes to the default branch, as a backstop where up-to-date branches aren't required.

```yaml
name: Decision records

on:
  pull_request:
  push:
    branches: [main]

jobs:
  decision-records:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
      - uses: powerhome/github-actions-workflows/decision-records@<pinned-commit-sha>
        with:
          adr-directories: docs/decisions
          cir-directories: docs/cir
```

| Input | Default | Description |
|---|---|---|
| `adr-directories` | `docs/decisions` | ADR directories, one per line, relative to the repository root. Empty checks no ADRs. A monorepo lists one directory per component. |
| `cir-directories` | empty | CIR directories, one per line. Empty checks no CIRs. |
| `mkdocs-config` | `mkdocs.yml` | MkDocs config for the nav check. Empty, or a file that does not exist, skips it. |

The action runs on the runner's preinstalled Ruby and needs no other setup.

## Jenkins and local runs

The script needs only Ruby 3.1 or later and its standard library, so a Jenkins stage or a developer can run it from a checkout of this repository:

```sh
ruby decision-records/bin/check_decision_records.rb --root path/to/repo \
  --adr docs/decisions --cir docs/cir --mkdocs mkdocs.yml
```

`--adr` and `--cir` repeat for several directories. It exits 1 when it finds a problem, and prints each as `path: message`.

## Tests

```sh
GEM_HOME="$(mktemp -d)" ruby decision-records/spec/run_all.rb
```
