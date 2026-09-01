require_relative "../../spec_helper"
require "test_plan/playbook/parser"

require "json"

RSpec.describe TestPlan::Playbook::Parser do
  def payload(overrides = {})
    {
      "kits" => [
        {
          "name" => "Dropdown", "code" => "DRP", "use_count" => 3,
          "what_changed" => "Dynamic options can now come from a hook.",
          "cases" => [
            { "title" => "Reminder Calls filter", "page" => "/contact_center/reminder_calls",
              "source" => "components/contact_center/index.html.erb", "access" => "Contact Center — Read",
              "steps" => ["Open the dropdown."] },
          ],
        },
      ],
    }.merge(overrides)
  end

  def parse(overrides = {})
    described_class.new(JSON.generate(payload(overrides)))
  end

  it "reads kits, their cases and the evidence each case names" do
    kit = parse.kits.first

    expect(kit).to include("name" => "Dropdown", "code" => "DRP", "use_count" => 3)
    expect(kit.fetch("cases").first).to include(
      "title" => "Reminder Calls filter",
      "page" => "/contact_center/reminder_calls",
      "access" => "Contact Center — Read"
    )
  end

  it "requires a kits array" do
    expect { described_class.new(JSON.generate("cross_cutting" => [])) }
      .to raise_error(/must include a "kits" array/)
  end

  it "drops a kit with no usable cases and says so rather than failing the run" do
    parsed = parse("kits" => [{ "name" => "Dropdown", "cases" => [{ "title" => "No steps" }] }])

    expect(parsed.kits).to be_empty
    expect(parsed.discarded.join).to include("had no steps")
  end

  # The count drives the coverage tier, so a count below the number of cases would render
  # as exhaustive while listing more pages than it claims exist.
  it "never reports a use count below the cases it lists" do
    parsed = parse(
      "kits" => [
        {
          "name" => "Body", "use_count" => 1,
          "cases" => [
            { "title" => "One", "steps" => ["a"] },
            { "title" => "Two", "steps" => ["b"] },
          ],
        },
      ]
    )

    expect(parsed.kits.first.fetch("use_count")).to eq(2)
  end

  it "falls back to a code derived from the kit name" do
    expect(parse("kits" => [{ "name" => "File Upload", "cases" => [{ "title" => "x", "steps" => ["y"] }] }])
      .kits.first.fetch("code")).to eq("FIL")
  end

  it "reads the sections beyond the kits" do
    parsed = parse(
      "cross_cutting" => [
        { "area" => "Tokens", "paths" => ["tokens/_colors.scss"], "risk" => "Layout drift.", "steps" => ["Spot-check."] },
      ],
      "other_dependencies" => [{ "name" => "cgi", "from" => "0.5.1", "to" => "0.5.2", "note" => "Patch bump." }]
    )

    expect(parsed.cross_cutting.first).to include("area" => "Tokens", "risk" => "Layout drift.")
    expect(parsed.other_dependencies.first).to include("name" => "cgi", "from" => "0.5.1", "to" => "0.5.2")
  end

  it "treats both sections as optional" do
    parsed = parse

    expect(parsed.cross_cutting).to be_empty
    expect(parsed.other_dependencies).to be_empty
  end

  it "recovers JSON from a fenced response" do
    fenced = "Here you go:\n```json\n#{JSON.generate(payload)}\n```\n"

    expect(described_class.new(fenced).kits.first.fetch("name")).to eq("Dropdown")
  end
end
