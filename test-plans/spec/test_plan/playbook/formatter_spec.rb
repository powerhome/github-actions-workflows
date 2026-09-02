require_relative "../../spec_helper"
require "test_plan/playbook/formatter"
require "test_plan/playbook/kit_facts"
require "test_plan/playbook/parser"

require "json"

RSpec.describe TestPlan::Playbook::Formatter do
  KF = TestPlan::Playbook::KitFacts

  def kit(name:, slug: nil, cases: 1, code: nil, system: "rails")
    {
      "name" => name, "slug" => slug || name.downcase, "code" => code,
      "what_changed" => "Behaviour moved.",
      "cases" => Array.new(cases) do |index|
        { "title" => "Page #{index + 1}", "page" => "/page/#{index + 1}", "system" => system,
          "steps" => ["Confirm it still works."] }
      end,
    }
  end

  def facts(*entries)
    KF.new(KF.document(entries).fetch("kits"))
  end

  def fact(slug:, name:, coverage:, call_sites:, systems_changed: ["rails"], systems_in_use: ["rails"])
    { slug: slug, name: name, coverage: coverage, call_sites: call_sites,
      systems_changed: systems_changed, systems_in_use: systems_in_use }
  end

  def render(payload, warning: "", kit_facts: KF.none)
    described_class.new(
      parsed: TestPlan::Playbook::Parser.new(JSON.generate(payload)),
      pull_request_title: "Playbook RC 17.2.0.pre.rc.0",
      profile_name: "Cobra Test Plan",
      generation_warning: warning,
      kit_facts: kit_facts
    ).render
  end

  it "leads with the regression framing, because nothing here is a new feature" do
    output = render({ "kits" => [kit(name: "Dropdown")] })

    expect(output).to start_with("## ✅ Cobra Test Plan: Playbook RC 17.2.0.pre.rc.0")
    expect(output).to include("> **Every case below is a regression test.**")
    expect(output).not_to include("## Regression Testing")
  end

  # Stakeholders asked for it gone; the cases themselves carry the coverage wording.
  it "has no coverage table" do
    output = render({ "kits" => [kit(name: "Dropdown"), kit(name: "Body")] })

    expect(output).not_to include("## Coverage at a Glance")
    expect(output).not_to include("| Kit |")
    expect(output).to start_with("## ✅")
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

    # Never upgrade coverage on the provider's word alone.
    it "reads as a sample when no fact matched the kit" do
      output = render({ "kits" => [kit(name: "Dropdown", slug: "mismatched")] })

      expect(output).to include(KF::REPRESENTATIVE_SENTENCE)
    end

    # What the parser's old use_count clamp was really protecting: "every use is listed
    # below" must not appear above a list shorter than the call sites.
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
