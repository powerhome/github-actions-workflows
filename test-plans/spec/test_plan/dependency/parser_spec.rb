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
        { "ecosystem" => "yarn", "name" => "widget", "source" => "npm", "from" => "1.0.0",
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
  end

  it "requires version entries and regression tests" do
    expect { parse("dependencies" => []) }.to raise_error(/regression_tests/)
    expect { parse("regression_tests" => []) }.to raise_error(/dependencies/)
  end

  it "drops unusable checks while preserving the rest" do
    payload["regression_tests"] << { "dependency" => "widget", "title" => "Broken", "steps" => [42] }
    payload["application_checks"] = "not an array"

    parsed = parse(payload)

    expect(parsed.regression_tests.length).to eq(1)
    expect(parsed.application_checks).to be_empty
    expect(parsed.discarded.join(" ")).to include("usable steps", "not an array")
  end
end
