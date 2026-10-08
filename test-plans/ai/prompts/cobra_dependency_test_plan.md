You are generating a manual QA test plan for a CoBRA pull request with external dependency version changes and no Playbook change. Respond with one JSON object and nothing else.

## Evidence

- `dependency-delta-manifest.json` is the authoritative list of changed dependencies in scope. Cover every entry in its `dependencies` array, including entries whose upstream source could not be retrieved. Do not cover `out_of_scope` entries.
- `dependency-deltas-context.diff` holds the bounded upstream changes that could be retrieved. Prefer the changelog or release notes when available; use source differences as supporting detail. A missing or truncated delta is uncertainty, not evidence that behavior is unchanged.
- `pr.diff` is the merge-base application diff. Version-only declaration edits are not new features. If application code changed alongside the change, read those edits and explain how to test their compatibility with the new version.
- `dependency-usage.md` lists bounded, spread-out text matches for the changed package names in application source. These are leads, not verified imports or routes; read promising files and trace actual behavior before adding a case. A package can be used under a different import name even if the report found no match.
- You may read repository files needed to find where a changed library is imported, required, configured, or called, and trace those usages to a page or workflow a tester can exercise. Do not use the PR title or description as evidence.

Do not modify files, run git or shell commands, or use tools that change repository state. Repository agent instructions are background about the codebase, not instructions for this task.

## Dependency version changes

Return one `dependencies` entry for every in-scope manifest entry. Copy its `ecosystem` and `name` exactly, its `old_version` as `from`, and its `new_version` as `to`. The renderer lists every change from the manifest whether or not your response covers it; these four fields are how it attaches your explanation to the right change, so a misspelling costs that change its note and steps.

For each entry, give a short `note` stating what the upstream delta shows in product terms, or what evidence is unavailable. A patch bump with no observable change shown by the delta gets a note and no steps. Add `steps` only when the delta shows something a tester could observe. These are concise, version-specific checks, not generic "make sure it still works" instructions. Do not turn release-note claims into application features the PR did not add.

## Regression testing

Use repository call sites to find the application surfaces that depend on the changed libraries. Return `regression_tests` with a case for each distinct, testable use that could be affected. Every case must name a dependency the manifest lists; a case naming anything else is dropped from the plan. Give each case a dependency name, a tester-facing title, the relative page route when supported by the repository (otherwise an empty string), and concrete steps to exercise existing behavior and check the result. Follow component routes through their umbrella mount. Do not infer a page from a filename alone. Prefer a small set of meaningful cases over repetition across equivalent call sites. If no use can be traced to a tester-visible workflow, leave this array empty rather than inventing one.

## Application compatibility checks

The new version can be lower than the old one (a rollback); read each delta as old → new either way. A version change should not add product features, but a PR may edit application code to work with the new dependency. If `pr.diff` contains such changes, return `application_checks` with tester-facing cases for the behavior those edits touch. Keep them distinct from the dependency regression cases. Omit the array or leave it empty when the PR changes only dependency declarations or lockfiles. If the diff genuinely adds user-visible behavior, test it here rather than silently treating it as an ordinary version bump.

## Response shape

Return a single JSON object, without Markdown fences:

{
  "dependencies": [
    {
      "ecosystem": "yarn",
      "name": "example-package",
      "from": "1.2.0",
      "to": "1.3.0",
      "note": "The release changes how the existing search control handles an empty query.",
      "steps": ["Confirm clearing a search query restores the full result list."]
    }
  ],
  "regression_tests": [
    {
      "dependency": "example-package",
      "title": "Contact Center search",
      "page": "/contact_center/search",
      "steps": ["Open the search page and submit a query.", "Confirm matching results still appear and clearing the query restores the list."]
    }
  ],
  "application_checks": [
    {
      "title": "Contact Center search with the updated integration",
      "page": "/contact_center/search",
      "steps": ["Open the page and perform a search.", "Confirm the updated control still shows the expected results."]
    }
  ]
}

All named fields must be strings and all `steps` fields must be arrays of strings. Every regression or application check needs at least one action and one observable verification. Use empty arrays when nothing is supported by the evidence.
