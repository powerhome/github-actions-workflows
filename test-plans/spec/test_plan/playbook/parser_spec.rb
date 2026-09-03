require_relative "../../spec_helper"
require "test_plan/playbook/parser"

require "json"

RSpec.describe TestPlan::Playbook::Parser do
  def payload(overrides = {})
    {
      "kits" => [
        {
          "name" => "Dropdown", "slug" => "dropdown", "code" => "DRP",
          "what_changed" => "Dynamic options can now come from a hook.",
          "cases" => [
            { "title" => "Reminder Calls filter", "page" => "/contact_center/reminder_calls",
              "system" => "rails", "steps" => ["Open the dropdown."] },
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

    expect(kit).to include("name" => "Dropdown", "slug" => "dropdown", "code" => "DRP")
    expect(kit.fetch("cases").first).to include(
      "title" => "Reminder Calls filter",
      "page" => "/contact_center/reminder_calls",
      "system" => "rails"
    )
  end

  # The join key into the facts the action computed, which is why no count travels here.
  it "carries no use count of its own" do
    expect(parse.kits.first).not_to have_key("use_count")
  end

  it "keeps a case's system only when it names one this action understands" do
    parsed = parse(
      "kits" => [
        {
          "name" => "Dropdown",
          "cases" => [
            { "title" => "A", "system" => "React", "steps" => ["x"] },
            { "title" => "B", "system" => "haskell", "steps" => ["y"] },
            { "title" => "C", "steps" => ["z"] },
          ],
        },
      ]
    )

    expect(parsed.kits.first.fetch("cases").map { |c| c.fetch("system") }).to eq(["react", "", ""])
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

  it "falls back to a code derived from the kit name" do
    expect(parse("kits" => [{ "name" => "File Upload", "cases" => [{ "title" => "x", "steps" => ["y"] }] }])
      .kits.first.fetch("code")).to eq("FIL")
  end

  it "reads the dependency raises beyond the kits" do
    parsed = parse(
      "other_dependencies" => [{ "name" => "cgi", "from" => "0.5.1", "to" => "0.5.2", "note" => "Patch bump." }]
    )

    expect(parsed.other_dependencies.first).to include("name" => "cgi", "from" => "0.5.1", "to" => "0.5.2")
  end

  it "treats the dependency raises as optional" do
    expect(parse.other_dependencies).to be_empty
  end

  # Playbook's own version constant, packaging and docs site are not a tester's problem,
  # so there is nowhere for the provider to write them up any more.
  it "has no place for Playbook internals" do
    expect(parse).not_to respond_to(:cross_cutting)
  end

  it "recovers JSON from a fenced response" do
    fenced = "Here you go:\n```json\n#{JSON.generate(payload)}\n```\n"

    expect(described_class.new(fenced).kits.first.fetch("name")).to eq("Dropdown")
  end
end
