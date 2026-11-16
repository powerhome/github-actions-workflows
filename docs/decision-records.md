# Decision Records

The `decision-records` composite action checks a repository's architecture decision records (ADRs, in [MADR 4.0.0](https://adr.github.io/madr/) format) and change intent records (CIRs), as [RFC 0115](https://github.com/powerhome/rfcs/pull/240) sets out. It fails a build when two records share a number, a file is misnamed, an ADR's front matter is missing or invalid, a required section is missing, a supersession names a record that does not exist, or a record is missing from an explicit MkDocs nav.

Run it on pull requests and again on pushes to the default branch, so that two pull requests that took the same number in parallel are caught as soon as the second merges.

See the repository's [`decision-records/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/decision-records/README.md) for the full list of checks, the action's inputs, a caller example, and how to run the same check from Jenkins or locally.
