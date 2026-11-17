# Decision Records

The `decision-records` composite action checks a repository's architecture decision records (ADRs, in [MADR 4.0.0](https://adr.github.io/madr/) format) and change intent records (CIRs), as [RFC 0110](https://github.com/powerhome/rfcs/pull/240) sets out. It fails a build when two records share a number, the numbers skip one, a file is misnamed, an ADR's front matter is missing or invalid, a required section is missing, a supersession names a record that does not exist, or a record is missing from an explicit MkDocs nav.

Records are numbered from the default branch, and two open pull requests can race for the same number: the loser merges the default branch in and renumbers. Run the check on pull requests with up-to-date branches required, so the loser fails before it merges, and on pushes to the default branch as a backstop.

See the repository's [`decision-records/README.md`](https://github.com/powerhome/github-actions-workflows/blob/main/decision-records/README.md) for the full list of checks, the action's inputs, a caller example, and how to run the same check from Jenkins or locally.
