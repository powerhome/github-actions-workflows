require_relative "../../spec_helper"
require "test_plan/playbook/formatter"
require "test_plan/playbook/parser"

require "json"

RSpec.describe TestPlan::Playbook::Formatter do
  def kit(name:, use_count:, cases: 1, code: nil)
    {
      "name" => name, "code" => code, "use_count" => use_count,
      "what_changed" => "Behaviour moved.",
      "cases" => Array.new(cases) do |index|
        { "title" => "Page #{index + 1}", "page" => "/page/#{index + 1}", "steps" => ["Confirm it still works."] }
      end,
    }
  end

  def render(payload, warning: "")
    described_class.new(
      parsed: TestPlan::Playbook::Parser.new(JSON.generate(payload)),
      pull_request_title: "Playbook RC 17.2.0.pre.rc.0",
      profile_name: "Cobra Test Plan",
      generation_warning: warning
    ).render
  end

  it "leads with the regression framing, because nothing here is a new feature" do
    output = render({ "kits" => [kit(name: "Dropdown", use_count: 3)] })

    expect(output).to start_with("## ✅ Cobra Test Plan: Playbook RC 17.2.0.pre.rc.0")
    expect(output).to include("> **Every case below is a regression test.**")
    # There is no separate regression section; the functional cases are it.
    expect(output).not_to include("## Regression Testing")
  end

  it "answers breadth before any case" do
    output = render({ "kits" => [kit(name: "Dropdown", use_count: 3), kit(name: "Body", use_count: 214, cases: 2)] })

    expect(output.index("## Coverage at a Glance")).to be < output.index("## Regression Coverage by Kit")
    expect(output).to include("| Kit | Uses in app | Coverage | Cases |")
    expect(output).to include("| Dropdown | 3 | Complete |")
    expect(output).to include("| Body | 214 | Representative |")
  end

  # The tier is derived from the count here rather than taken from the provider, so a
  # sample can never be published as exhaustive.
  it "calls a narrowly used kit complete and says nothing is sampled" do
    output = render({ "kits" => [kit(name: "Dropdown", use_count: described_class::COMPLETE_COVERAGE_MAX)] })

    expect(output).to include("· complete coverage")
    expect(output).to include("every use in this repository is listed below. Nothing is sampled.")
  end

  it "calls a widely used kit representative and says how many it sampled" do
    output = render({ "kits" => [kit(name: "Body", use_count: described_class::COMPLETE_COVERAGE_MAX + 1, cases: 3)] })

    expect(output).to include("· representative sample")
    expect(output).to include("used in 5 files across the application")
    expect(output).to include("the 3 pages below are a **representative sample**")
  end

  it "numbers cases from the kit's code" do
    output = render({ "kits" => [kit(name: "Dropdown", use_count: 3, cases: 2, code: "DRP")] })

    expect(output).to include("#### DRP-1 — Page 1", "#### DRP-2 — Page 2")
    expect(output).to include("| DRP-1 – DRP-2 |")
  end

  # A Playbook raise changes no permissions, so access belongs on the case rather than in
  # a section that would always say "not identified".
  it "carries access on the case instead of a permissions section" do
    output = render(
      { "kits" => [
        {
          "name" => "Dropdown", "use_count" => 1,
          "cases" => [{ "title" => "Filter", "page" => "/x", "access" => "Contact Center — Read", "steps" => ["Open it."] }],
        },
      ] }
    )

    expect(output).to include("**Access:** Contact Center — Read")
    expect(output).not_to include("## Permissions / Roles")
  end

  describe "beyond the kits" do
    it "renders cross-cutting changes and other raises" do
      output = render(
        { "kits" => [kit(name: "Dropdown", use_count: 1)],
          "cross_cutting" => [
          { "area" => "Global props / tokens", "paths" => ["tokens/_colors.scss"],
            "risk" => "Shows as layout drift.", "steps" => ["Spot-check a dense page."] },
        ],
          "other_dependencies" => [
            { "name" => "cgi", "from" => "0.5.1", "to" => "0.5.2", "note" => "Patch bump. No dedicated testing." },
          ] }
      )

      expect(output).to include("## Beyond the Kits")
      expect(output).to include("### Playbook changes not scoped to a kit", "**Global props / tokens**")
      expect(output).to include("`tokens/_colors.scss`", "Shows as layout drift.")
      expect(output).to include("### Other dependency raises in this PR")
      expect(output).to include("- **cgi 0.5.1 → 0.5.2** — Patch bump. No dedicated testing.")
    end

    # Says the check ran, rather than leaving a reader to wonder whether it did.
    it "says so when there is nothing beyond the kits" do
      output = render({ "kits" => [kit(name: "Dropdown", use_count: 1)] })

      expect(output).to include("No Playbook changes outside the kits were identified.")
      expect(output).to include("No other dependency raises in this PR.")
    end
  end

  it "escapes provider text so a plan cannot mention anyone or link anywhere" do
    output = render(
      { "kits" => [
        {
          "name" => "<img src=q onerror=alert(1)>", "use_count" => 1,
          "cases" => [{ "title" => "Ping @someone", "page" => "https://example.test/phish", "steps" => ["[click](https://example.test)"] }],
        },
      ] }
    )

    expect(output).not_to include("<img", "@someone")
    expect(output).to include("&lt;img", "&#64;someone", "https&#58;//example.test")
    expect(output).to include("\\[click\\]")
  end

  it "carries the dependency-delta warning and the discard notice" do
    output = render(
      { "kits" => [kit(name: "Dropdown", use_count: 1), { "name" => "Broken", "cases" => [] }] },
      warning: "Some external dependency evidence is incomplete: irb (provider context budget exhausted)."
    )

    expect(output).to include("> ⚠️ Some external dependency evidence is incomplete")
    expect(output).to include("part of the generated response could not be used")
  end

  it "says so when no kit survived" do
    output = render({ "kits" => [] })

    expect(output).to include("No changed Playbook kits were identified for this upgrade.")
  end
end
