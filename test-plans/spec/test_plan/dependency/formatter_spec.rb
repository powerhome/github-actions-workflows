require_relative "../../spec_helper"
require "test_plan/dependency/formatter"
require "test_plan/dependency/parser"

require "json"

RSpec.describe TestPlan::Dependency::Formatter do
  let(:manifest) do
    { "dependencies" => [
      { "ecosystem" => "yarn", "name" => "widget", "source" => "npm",
        "old_version" => "1.0.0", "new_version" => "2.0.0", "status" => "retrieved" },
      { "ecosystem" => "bundler", "name" => "cgi", "source" => "rubygems",
        "old_version" => "0.5.1", "new_version" => "0.5.2", "status" => "unavailable" },
    ] }
  end

  def render(payload)
    parsed = TestPlan::Dependency::Parser.new(JSON.generate(payload))
    described_class.new(
      parsed: parsed, manifest: manifest, pull_request_title: "Raise dependencies",
      profile_name: "Cobra Test Plan"
    ).render
  end

  it "lists every manifest raise and uses provider notes only for exact matches" do
    output = render(
      "dependencies" => [
        { "ecosystem" => "yarn", "name" => "widget", "source" => "npm", "from" => "1.0.0",
          "to" => "2.0.0", "note" => "The existing menu handles empty selections differently.",
          "steps" => ["Confirm clearing the menu restores its default state."] },
      ],
      "regression_tests" => []
    )

    expect(output).to include("## Dependency version changes")
    expect(output).to include("**widget (yarn) 1.0.0 → 2.0.0**")
    expect(output).to include("Confirm clearing the menu restores its default state.")
    expect(output).to include("**cgi (bundler) 0.5.1 → 0.5.2**")
    expect(output).to include("Upstream delta unavailable")
    expect(output).not_to include("Other dependency raises", "Applicable Functional Cases")
  end

  it "renders usage-based regression tests and separate application compatibility checks" do
    output = render(
      "dependencies" => [],
      "regression_tests" => [
        { "dependency" => "widget", "title" => "Contact Center menu", "page" => "/contact_center/menu",
          "steps" => ["Open the menu.", "Confirm the selection still persists."] },
        { "dependency" => "made-up", "title" => "Unrelated page", "steps" => ["Open it."] },
      ],
      "application_checks" => [
        { "title" => "Updated menu integration", "page" => "/contact_center/menu",
          "steps" => ["Open the menu.", "Confirm it still renders."] },
      ]
    )

    expect(output).to include("## Regression Testing", "### Contact Center menu")
    expect(output).to include("**Dependency:** widget", "**Page:** /contact_center/menu")
    expect(output).to include("## Application Compatibility Checks", "### Updated menu integration")
    expect(output).not_to include("Unrelated page", "Applicable Functional Cases")
  end

  it "escapes untrusted text while preserving inline code" do
    output = render(
      "dependencies" => [],
      "regression_tests" => [
        { "dependency" => "widget", "title" => "Ping @team <img>", "page" => "`/menu`",
          "steps" => ["Open `/menu` and check [link](https://example.test)."] },
      ]
    )

    expect(output).to include("&#64;team &lt;img&gt;", "**Page:** `/menu`", "Open `/menu`")
    expect(output).not_to include("@team <img>", "https://example.test")
  end
end
