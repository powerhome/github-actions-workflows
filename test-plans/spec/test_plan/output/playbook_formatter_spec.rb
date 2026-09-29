# frozen_string_literal: true

require_relative "../../spec_helper"
require "test_plan/output/playbook_formatter"
require "test_plan/playbook/kit_facts"
require "test_plan/response/playbook_parser"

require "json"

RSpec.describe TestPlan::Output::PlaybookFormatter do
  KF = TestPlan::Playbook::KitFacts

  def kit(name:, slug: nil, cases: 1, code: nil, system: "rails")
    {
      "name" => name, "slug" => slug || name.downcase, "code" => code,
      "what_changed" => "Behaviour moved.",
      "cases" => Array.new(cases) do |index|
        { "title" => "Page #{index + 1}", "page" => "/page/#{index + 1}", "system" => system,
          "steps" => ["Open page #{index + 1}.", "Confirm page #{index + 1} still works."] }
      end,
    }
  end

  def facts(*entries)
    KF.new(KF.document(entries).fetch("kits"))
  end

  def fact(slug:, name:, coverage:, call_sites:, systems_changed: ["rails"], systems_in_use: ["rails"])
    { slug:, name:, coverage:, call_sites:,
      systems_changed:, systems_in_use: }
  end

  def render(payload, warning: "", kit_facts: KF.none)
    described_class.new(
      parsed: TestPlan::Response::PlaybookParser.new(JSON.generate(payload)),
      pull_request_title: "Playbook RC 17.2.0.pre.rc.0",
      profile_name: "Cobra Test Plan",
      generation_warning: warning,
      kit_facts:
    ).render
  end

  it "leads with the regression framing, because nothing here is a new feature" do
    output = render({ "kits" => [kit(name: "Dropdown")] })

    expect(output).to start_with("## ✅ Cobra Test Plan: Playbook RC 17.2.0.pre.rc.0")
    expect(output).to include("> **Every kit case below is a regression test.**")
    expect(output).not_to include("## Regression Testing")
  end

  # Stakeholders asked for it gone; the cases themselves carry the coverage wording.
  it "has no coverage table" do
    output = render({ "kits" => [kit(name: "Dropdown"), kit(name: "Body")] })

    expect(output).not_to include("## Coverage at a Glance")
    expect(output).not_to include("| Kit |")
    expect(output).to start_with("## ✅")
  end

  # Nothing asserted the steps until deleting the line that renders them left the suite
  # green.
  it "renders every step of every case, in the order they were written" do
    output = render({ "kits" => [kit(name: "Dropdown", cases: 2)] })

    expect(output).to include("- Open page 1.\n- Confirm page 1 still works.")
    expect(output).to include("- Open page 2.\n- Confirm page 2 still works.")
  end

  it "keeps each case's steps under that case rather than pooling them" do
    output = render({ "kits" => [kit(name: "Dropdown", cases: 2, code: "DRP")] })

    first = output.index("#### DRP-1")
    second = output.index("#### DRP-2")
    expect(output.index("Open page 1.")).to be_between(first, second)
    expect(output.index("Open page 2.")).to be > second
  end

  it "carries only the page and the system on a case" do
    output = render({ "kits" => [kit(name: "Dropdown", system: "react")] })

    expect(output).to include("**Page:** /page/1")
    expect(output).to include("**System:** React")
    expect(output).not_to include("**Source:**")
    expect(output).not_to include("**Access:**")
    expect(output).not_to include("## Permissions / Roles")
  end

  describe "coverage, decided from what the action counted" do
    it "says every use is listed when the action found the kit exhaustible" do
      output = render(
        { "kits" => [kit(name: "Dropdown", cases: 3)] },
        kit_facts: facts(fact(slug: "dropdown", name: "Dropdown", coverage: KF::COMPLETE, call_sites: 3))
      )

      expect(output).to include("**Coverage:** #{KF::COMPLETE_SENTENCE}")
    end

    it "says representative sample when the kit is used widely, and prints no count" do
      output = render(
        { "kits" => [kit(name: "Body", cases: 4)] },
        kit_facts: facts(fact(slug: "body", name: "Body", coverage: KF::REPRESENTATIVE, call_sites: 1106))
      )

      expect(output).to include("**Coverage:** #{KF::REPRESENTATIVE_SENTENCE}")
      # The count stays in the facts file and the job summary, never in the comment.
      expect(output).not_to include("1106")
      expect(output).not_to include("4 pages")
    end

    it "says so when nothing in this repository uses the kit" do
      output = render(
        { "kits" => [kit(name: "Dialog")] },
        kit_facts: facts(
          fact(slug: "dialog", name: "Dialog", coverage: KF::UNUSED, call_sites: 0, systems_in_use: [])
        )
      )

      expect(output).to include(KF::UNUSED_SENTENCE)
    end

    # A failed grep cannot say how widely the kit is used, and a representative sample
    # claims it anyway while hiding the failure.
    it "says the usage search failed rather than claiming a sample" do
      output = render(
        { "kits" => [kit(name: "Dropdown")] },
        kit_facts: facts(
          fact(slug: "dropdown", name: "Dropdown", coverage: KF::UNKNOWN, call_sites: 0,
               systems_in_use: [])
        )
      )

      expect(output).to include(KF::UNKNOWN_SENTENCE)
      expect(output).not_to include(KF::REPRESENTATIVE_SENTENCE)
    end

    # Never upgrade coverage on the provider's word alone.
    it "reads as a sample when no fact matched the kit" do
      output = render({ "kits" => [kit(name: "Dropdown", slug: "mismatched")] })

      expect(output).to include(KF::REPRESENTATIVE_SENTENCE)
    end

    # "Every use is listed below" must not appear above a list shorter than the call sites.
    it "downgrades an exhaustible kit the provider under-covered" do
      output = render(
        { "kits" => [kit(name: "Dropdown", cases: 1)] },
        kit_facts: facts(fact(slug: "dropdown", name: "Dropdown", coverage: KF::COMPLETE, call_sites: 4))
      )

      expect(output).to include(KF::REPRESENTATIVE_SENTENCE)
      expect(output).not_to include(KF::COMPLETE_SENTENCE)
    end
  end

  describe "which side of the kit changed" do
    it "names the changed systems on the kit heading" do
      output = render(
        { "kits" => [kit(name: "Dropdown")] },
        kit_facts: facts(
          fact(slug: "dropdown", name: "Dropdown", coverage: KF::REPRESENTATIVE, call_sites: 20,
               systems_changed: %w[rails react], systems_in_use: %w[rails react])
        )
      )

      expect(output).to include("### Dropdown — Rails and React")
    end

    it "notes a changed system nothing here renders" do
      output = render(
        { "kits" => [kit(name: "Dropdown")] },
        kit_facts: facts(
          fact(slug: "dropdown", name: "Dropdown", coverage: KF::REPRESENTATIVE, call_sites: 20,
               systems_changed: %w[rails react], systems_in_use: ["rails"])
        )
      )

      expect(output).to include("changed the React side of this kit, but nothing in this repository renders it")
    end
  end

  it "numbers cases from the kit's code" do
    output = render({ "kits" => [kit(name: "Dropdown", cases: 2, code: "DRP")] })

    expect(output).to include("#### DRP-1 — Page 1", "#### DRP-2 — Page 2")
  end

  it "lists the Playbook raise and covers non-kit regressions and application edits" do
    payload = {
      "kits" => [],
      "regression_tests" => [
        { "title" => "Existing control", "page" => "/control",
          "steps" => ["Open the control.", "Confirm it still works."] },
      ],
      "application_checks" => [
        { "title" => "Adjusted call site", "page" => "/control",
          "steps" => ["Open the control.", "Confirm the adjusted integration works."] },
      ]
    }
    parsed = TestPlan::Response::PlaybookParser.new(JSON.generate(payload))
    output = described_class.new(
      parsed:, pull_request_title: "Playbook upgrade", profile_name: "Cobra Test Plan",
      manifest: { "dependencies" => [
        { "name" => "playbook_ui", "old_version" => "17.0.0", "new_version" => "17.1.0" },
      ] }
    ).render

    expect(output).to include("## Playbook version changes", "playbook_ui 17.0.0 → 17.1.0")
    expect(output).to include("No changed Playbook kits were identified")
    expect(output).to include("## Additional Playbook Regression Testing", "### Existing control")
    expect(output).to include("## Application Compatibility Checks", "### Adjusted call site")
  end

  it "lists other manifest raises even when the provider omits them" do
    parsed = TestPlan::Response::PlaybookParser.new(JSON.generate("kits" => []))
    output = described_class.new(
      parsed:, pull_request_title: "Playbook upgrade", profile_name: "Cobra Test Plan",
      manifest: { "dependencies" => [
        { "name" => "playbook_ui", "old_version" => "17.0.0", "new_version" => "17.1.0" },
        { "name" => "cgi", "old_version" => "0.5.1", "new_version" => "0.5.2" },
      ] }
    ).render

    expect(output).to include("**cgi 0.5.1 → 0.5.2** — Raised alongside the Playbook upgrade.")
    expect(output).not_to include("No other dependency raises in this PR.")
  end

  # One the response invented has no raise to attach to; one it forgot still appears.
  it "ignores an other-dependency entry the manifest does not list" do
    parsed = TestPlan::Response::PlaybookParser.new(JSON.generate(
                                                      "kits" => [],
                                                      "other_dependencies" => [
                                                        { "name" => "cgi", "from" => "0.5.1", "to" => "0.5.2",
                                                          "note" => "Matched." },
                                                        { "name" => "invented", "from" => "1.0.0", "to" => "2.0.0",
                                                          "note" => "Not in the manifest." },
                                                      ]
                                                    ))
    output = described_class.new(
      parsed:, pull_request_title: "Playbook upgrade", profile_name: "Cobra Test Plan",
      manifest: { "dependencies" => [
        { "name" => "playbook_ui", "old_version" => "17.0.0", "new_version" => "17.1.0" },
        { "name" => "cgi", "old_version" => "0.5.1", "new_version" => "0.5.2" },
      ] }
    ).render

    expect(output).to include("**cgi 0.5.1 → 0.5.2** — Matched.")
    expect(output).not_to include("invented", "Not in the manifest.")
  end

  it "says the Playbook version is unavailable rather than inventing one" do
    parsed = TestPlan::Response::PlaybookParser.new(JSON.generate("kits" => []))
    output = described_class.new(
      parsed:, pull_request_title: "Playbook upgrade", profile_name: "Cobra Test Plan",
      manifest: { "dependencies" => [{ "name" => "cgi", "old_version" => "0.5.1", "new_version" => "0.5.2" }] }
    ).render

    expect(output).to include("## Playbook version changes", "Playbook version details were unavailable.")
  end

  # The npm half of the same release: also the Playbook raise, not an other dependency.
  it "recognises the npm package as a Playbook raise" do
    parsed = TestPlan::Response::PlaybookParser.new(JSON.generate("kits" => []))
    output = described_class.new(
      parsed:, pull_request_title: "Playbook upgrade", profile_name: "Cobra Test Plan",
      manifest: { "dependencies" => [
        { "name" => "playbook-ui", "old_version" => "17.0.0", "new_version" => "17.1.0" },
      ] }
    ).render

    expect(output).to include("## Playbook version changes", "playbook-ui 17.0.0 → 17.1.0")
    expect(output).to include("No other dependency raises in this PR.")
  end

  describe "beyond the kits" do
    it "lists the other dependency raises and nothing else" do
      output = render(
        {
          "kits" => [kit(name: "Dropdown")],
          "other_dependencies" => [
            { "name" => "cgi", "from" => "0.5.1", "to" => "0.5.2", "note" => "Patch bump. No dedicated testing." },
          ],
        }
      )

      expect(output).to include("## Other dependency raises in this PR")
      expect(output).to include("- **cgi 0.5.1 → 0.5.2** — Patch bump. No dedicated testing.")
      # Playbook's own version constant, packaging and docs site are not a tester's problem.
      expect(output).not_to include("Playbook changes not scoped to a kit")
    end

    it "says so when there were none" do
      output = render({ "kits" => [kit(name: "Dropdown")] })

      expect(output).to include("No other dependency raises in this PR.")
    end
  end

  it "escapes provider text so a plan cannot mention anyone or link anywhere" do
    output = render(
      { "kits" => [
        {
          "name" => "<img src=q onerror=alert(1)>",
          "cases" => [{ "title" => "Ping @someone", "page" => "https://example.test/phish",
                        "steps" => ["[click](https://example.test)"] }],
        },
      ] }
    )

    expect(output).not_to include("<img", "@someone")
    expect(output).to include("&lt;img", "&#64;someone", "https&#58;//example.test")
    expect(output).to include("\\[click\\]")
  end

  it "preserves backticks in pages and steps" do
    entry = kit(name: "Dropdown")
    entry["cases"][0]["page"] = "`/page/1`"
    entry["cases"][0]["steps"] = ["Open `/page/1`."]

    output = render({ "kits" => [entry] })

    expect(output).to include("**Page:** `/page/1`")
    expect(output).to include("- Open `/page/1`.")
  end

  it "carries the dependency-delta warning and the discard notice" do
    output = render(
      { "kits" => [kit(name: "Dropdown"), { "name" => "Broken", "cases" => [] }] },
      warning: "Some external dependency evidence is incomplete: irb (provider context budget exhausted)."
    )

    expect(output).to include("> ⚠️ Some external dependency evidence is incomplete")
    expect(output).to include("part of the generated response could not be used")
  end

  it "says so when no kit survived" do
    expect(render({ "kits" => [] })).to include("No changed Playbook kits were identified for this upgrade.")
  end
end
