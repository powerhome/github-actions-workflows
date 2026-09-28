require_relative "../../spec_helper"
require "test_plan/dependency/parser"

require "json"

RSpec.describe TestPlan::Dependency::Parser do
  def parse(payload)
    described_class.new(JSON.generate(payload))
  end

  let(:payload) do
    {
      "dependencies" => [
        { "ecosystem" => "yarn", "name" => "widget", "from" => "1.0.0",
          "to" => "2.0.0", "note" => "Existing menu behavior changed.", "steps" => ["Check the menu."] },
      ],
      "regression_tests" => [
        { "dependency" => "widget", "title" => "Menu", "page" => "/menu",
          "steps" => ["Open the menu.", "Confirm the selection persists."] },
      ],
      "application_checks" => [
        { "title" => "Updated menu integration", "page" => "/menu",
          "steps" => ["Open the menu.", "Confirm it still works."] },
      ],
    }
  end

  it "parses version notes, regression tests, and application checks" do
    parsed = parse(payload)

    expect(parsed.dependencies.first).to include("name" => "widget", "from" => "1.0.0", "to" => "2.0.0")
    expect(parsed.regression_tests.first).to include("dependency" => "widget", "page" => "/menu")
    expect(parsed.application_checks.first.fetch("title")).to eq("Updated menu integration")
    expect(parsed.discarded).to be_empty
  end

  it "requires the version entries the plan is built around" do
    expect { parse("regression_tests" => []) }.to raise_error(/dependencies/)
    expect { parse([]) }.to raise_error(/must be an object/)
  end

  # Sending no array says what an empty array says, and the manifest still supplies every
  # version change the plan is really about.
  it "accepts a response carrying version entries alone" do
    parsed = parse("dependencies" => payload.fetch("dependencies"))

    expect(parsed.dependencies.length).to eq(1)
    expect(parsed.regression_tests).to be_empty
    expect(parsed.application_checks).to be_empty
    expect(parsed.discarded).to be_empty
  end

  # `source` is an internal enum no reader of the plan sees, so requiring it back costs a
  # response its note and steps for nothing.
  it "keeps a version entry that did not echo the manifest's source" do
    parsed = parse("dependencies" => [
      { "ecosystem" => "yarn", "name" => "widget", "from" => "1.0.0", "to" => "2.0.0", "note" => "Changed." },
    ])

    expect(parsed.dependencies.first).to include("name" => "widget", "note" => "Changed.", "steps" => [])
    expect(parsed.discarded).to be_empty
  end

  it "drops unusable checks while preserving the rest" do
    payload["regression_tests"] << { "dependency" => "widget", "title" => "Broken", "steps" => [42] }
    payload["application_checks"] = "not an array"

    parsed = parse(payload)

    expect(parsed.regression_tests.length).to eq(1)
    expect(parsed.application_checks).to be_empty
    expect(parsed.discarded.join(" ")).to include("usable steps", "not an array")
  end

  it "drops a regression test that named no dependency" do
    parsed = parse(
      "dependencies" => [],
      "regression_tests" => [{ "title" => "Menu", "steps" => ["Open it.", "Confirm it works."] }]
    )

    expect(parsed.regression_tests).to be_empty
    expect(parsed.discarded.join(" ")).to include("named no dependency")
  end

  it "names each unusable version entry and why it went" do
    parsed = parse(
      "dependencies" => [
        "not an object",
        { "ecosystem" => "yarn", "name" => "", "from" => "1.0.0", "to" => "2.0.0" },
        { "ecosystem" => "yarn", "name" => "widget", "from" => "1.0.0", "to" => "2.0.0", "steps" => "Check it." },
      ],
      "regression_tests" => []
    )

    expect(parsed.dependencies).to be_empty
    expect(parsed.discarded).to eq(
      [
        "dependency 1 was not an object",
        "dependency 2 had no identity",
        "dependency 3 had invalid steps",
      ]
    )
  end
end
