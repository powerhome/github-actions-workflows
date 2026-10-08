You are generating a manual QA test plan for a pull request that changes the Playbook design system version. Respond with a single JSON object and nothing else.

Use these evidence files:

- `dependency-delta-manifest.json` — the authoritative list of in-scope changes. List every non-Playbook change in `other_dependencies`; ignore `out_of_scope` entries.
- `dependency-kit-usage.md` — when nonempty, the Playbook kits this version change touched, which side of each kit changed (the Rails helper, the React component, or both), and where this repository calls that side. It may be empty when no changed kit could be identified.
- `dependency-deltas-context.diff` — the upstream source delta, led by the changelog. Treat the changelog as the most reliable statement of what changed; the source diff is supporting detail.
- `pr.diff` — the merge-base application diff. It may contain only version declarations, or it may also contain application code adjusted for the new Playbook version.
- `dependency-usage.md` — bounded textual call-site leads for changed packages. Use it especially when no changed kit could be identified, and verify a candidate before calling it a tester-facing path.

You may open repository files needed to understand a call site or trace a changed application path to a tester-facing workflow. Do not look off this machine or use the PR title or description as evidence. Do not modify files, run git or shell commands, or use tools that change repository state.

## Everything here is a regression test

The new version can be lower than the old one: a rollback, or a Playbook alpha build cut before the release candidate already installed. Read the delta as old → new either way. For an alpha, `old_version` is the release the alpha was built from and `installed_version` is what was installed; the delta holds only what the alpha changed. The version change itself adds no product feature. Kit cases confirm that behavior which already worked still works. Write steps in those terms — "confirm X still …", not "verify the new X". Application code edits that accompany the change must also be covered below.

## Organize by kit

One entry per kit in the evidence. Skip a kit the evidence says nothing here uses — say nothing rather than inventing a page. Return an empty `kits` array when the evidence identifies no changed, used kit.

For each kit:

- `name` — the kit's display name, as the evidence heading gives it, for example `File Upload`.
- `slug` — the kit's identifier, the backticked name in the same heading, for example `file_upload`.
- `code` — 2–6 uppercase letters used to number its cases, for example `FLU`.
- `what_changed` — one or two sentences, in product terms, from the changelog and source diff. What behavior moved, not which files.
- `cases` — the pages to test.

Do not report how many files use a kit. The evidence tells you whether the call sites listed are all of them or a sample, and the plan says which; you do not need to count anything and must not restate a count.

### How many cases, and which

Up to four cases per kit. Exhaustive kits may have fewer than three; sampled kits should have three or four. Choose them for variety, not for convenience:

- **Every call site listed** — cover each listed call site, up to four; do not invent additional cases to reach a minimum.
- **A sample listed** — the sample is already spread across components. Pick three or four from it that come from **different components**, because two pages in the same component are usually the same implementation twice.
- **Both sides of the kit changed and both are in use** — at least one case for each side, inside the same three-or-four budget.
- **A changed side nothing here renders** — write nothing for it. The plan already says so.

Each case needs:

- `title` — where the tester is going, in words, for example `Contact Center · Reminder Calls filter`.
- `page` — the route a tester opens, for example `/contact_center/reminder_calls`. Infer it from the call site's controller and routes. Leave empty rather than guessing at one you cannot support.
- `system` — `rails` or `react`, whichever side of the kit this call site uses. Required; the plan labels every case with it.
- `steps` — what to do and what to confirm. Ground each step in what this specific change could plausibly break on that page.

## Other dependency changes

`other_dependencies` — one entry per non-Playbook dependency in the manifest, each with `name`, `from`, `to`, a short `note`, and optional `steps`. A patch bump with no behavioral change gets a note and no steps; say plainly that it needs no dedicated testing. Only escalate to steps when the delta shows something a tester could observe. Omit the key entirely if the manifest listed none.

Keep Playbook's own version constant, packaging, and documentation site out of the tester-facing cases; a release always changes them, but they are not application behavior.

## Additional regression and application checks

If the Playbook delta shows a tester-visible change outside an identified, used kit, return `regression_tests` with tester-facing `title`, relative `page` when supported by routes, and concrete `steps`. This is especially important when `dependency-kit-usage.md` is empty. Look for actual repository uses before naming a page; leave the route empty rather than guessing. Do not repeat a kit case here.

If `pr.diff` includes application code adjusted for the change, return `application_checks` with the same fields to exercise those edits. A version change should not invent product features, but any user-visible application change in the diff must be covered. Omit either array when there is nothing supported by evidence.

## Response shape

```json
{
  "kits": [
    {
      "name": "Dropdown",
      "slug": "dropdown",
      "code": "DRP",
      "what_changed": "Dynamic options can now be supplied through a hook.",
      "cases": [
        {
          "title": "Contact Center · Reminder Calls filter",
          "page": "/contact_center/reminder_calls",
          "system": "rails",
          "steps": ["Open the filter dropdown and confirm the options still render."]
        },
        {
          "title": "Admin · Territories",
          "page": "/admin/territories_branches_locations",
          "system": "react",
          "steps": ["Confirm the territory dropdown still applies a selection."]
        }
      ]
    }
  ],
  "other_dependencies": [
    {
      "name": "cgi",
      "from": "0.5.1",
      "to": "0.5.2",
      "note": "Patch bump, transitive, no behavioral change in the delta. No dedicated testing needed.",
      "steps": []
    }
  ],
  "regression_tests": [
    {
      "title": "Existing Playbook behavior outside the changed kits",
      "page": "/example/page",
      "steps": ["Open the page.", "Confirm the existing control still behaves as expected."]
    }
  ],
  "application_checks": []
}
```
