You are generating a manual QA test plan for a pull request that raises the Playbook design system version. Respond with a single JSON object and nothing else.

Every file in this pull request is a lockfile, so `pr.diff` will not tell you what to test. Your evidence is:

- `dependency-kit-usage.md` — the Playbook kits this upgrade changed, where this repository uses each one, and whether that list is exhaustive or a sample. This is what tells you which pages to cover. It also has a "Changes not scoped to a kit" section when the release changed things that belong to no kit.
- `dependency-deltas-context.diff` — the upstream source delta, led by the changelog. Treat the changelog as the most reliable statement of what changed; the source diff is supporting detail.
- `dependency-delta-manifest.json` — every dependency this pull request raised, including any that are not Playbook.

You may read repository files to understand how a page uses a kit. Do not create coverage for Playbook internals a tester cannot see.

## Everything here is a regression test

The upgrade adds no features to this application. Every case you write is confirming that behavior which already worked still works. Write steps in those terms — "confirm X still …", not "verify the new X". Do not write a separate regression section; there is nowhere for one to go.

## Organize by kit

One entry per changed kit that this repository actually uses. Skip a kit the repository never calls — say nothing rather than inventing a page.

For each kit:

- `name` — the kit's display name, for example `Dropdown` or `File Upload`.
- `code` — 2–6 uppercase letters used to number its cases, for example `DRP`.
- `what_changed` — one or two sentences, in product terms, from the changelog and source diff. What behavior moved, not which files.
- `use_count` — how many files use this kit, copied from `dependency-kit-usage.md`. Copy the number; do not estimate it.
- `cases` — the pages to test.

How many cases depends on how widely the kit is used, and `dependency-kit-usage.md` tells you which case you are in:

- **Every use listed** — write a case for each one. The plan will say the coverage is exhaustive.
- **A sample listed** — choose 3–4 that look most different from each other, preferring pages a tester can reach easily. The plan will say the coverage is representative. Do not apologize for sampling in your text; the plan states it.

Each case needs:

- `title` — where the tester is going, in words, for example `Contact Center · Reminder Calls filter`.
- `page` — the route a tester opens, for example `/contact_center/reminder_calls`. Infer it from the source file's controller and routes. Leave empty rather than guessing at one you cannot support.
- `source` — the repository-relative file that uses the kit, from the evidence.
- `access` — the role or permission needed to reach the page, if you can tell. Leave empty otherwise.
- `steps` — what to do and what to confirm. Ground each step in what the kit change could plausibly break on that page.

## Beyond the kits

- `cross_cutting` — Playbook changes belonging to no kit: tokens, global props, the `pb_rails` helper layer, React bindings. Use the "Changes not scoped to a kit" section of the evidence. Each entry has `area`, `paths`, `risk`, and optional `steps`. Omit the key entirely if there were none.
- `other_dependencies` — dependencies in the manifest other than `playbook_ui` and `playbook-ui`. Each has `name`, `from`, `to`, a short `note`, and optional `steps`. A patch bump with no behavioral change gets a note and no steps; say plainly that it needs no dedicated testing. Only escalate to steps when the delta shows something a tester could observe. Omit the key entirely if there were none.

Every line in these two lists must trace to a changed path or a raised dependency. Do not add general advice.

## Response shape

```json
{
  "kits": [
    {
      "name": "Dropdown",
      "code": "DRP",
      "what_changed": "Dynamic options can now be supplied through a hook.",
      "use_count": 3,
      "cases": [
        {
          "title": "Contact Center · Reminder Calls filter",
          "page": "/contact_center/reminder_calls",
          "source": "components/contact_center/app/views/reminder_calls/index.html.erb",
          "access": "Contact Center — Read",
          "steps": ["Open the filter dropdown and confirm the options still render."]
        }
      ]
    }
  ],
  "cross_cutting": [
    {
      "area": "Global props / tokens",
      "paths": ["app/pb_kits/playbook/tokens/_colors.scss"],
      "risk": "Applies to every kit; a regression shows as layout drift rather than a broken control.",
      "steps": ["Spot-check spacing and color on one dense page and one form-heavy page."]
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
  ]
}
```
