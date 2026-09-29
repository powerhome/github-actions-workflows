# frozen_string_literal: true
require_relative "../../spec_helper"
require "test_plan/output/dependency_formatter"
require "test_plan/response/dependency_parser"

require "json"

RSpec.describe TestPlan::Output::DependencyFormatter do
  let(:manifest) do
    { "dependencies" => [
      { "ecosystem" => "yarn", "name" => "widget", "source" => "npm",
        "old_version" => "1.0.0", "new_version" => "2.0.0", "status" => "retrieved" },
      { "ecosystem" => "bundler", "name" => "cgi", "source" => "rubygems",
        "old_version" => "0.5.1", "new_version" => "0.5.2", "status" => "unavailable" },
    ] }
  end

  def render(payload, warning = "")
    described_class.new(
      parsed: TestPlan::Response::DependencyParser.new(JSON.generate(payload)),
      manifest:, pull_request_title: "Raise dependencies",
      profile_name: "Cobra Test Plan", generation_warning: warning
    ).render
  end

  it "lists every manifest raise and uses provider notes only for exact matches" do
    output = render(
      "dependencies" => [
        { "ecosystem" => "yarn", "name" => "widget", "from" => "1.0.0",
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

  # Nothing was retrieved, or something was and the response said nothing about it.
  it "tells an unavailable delta apart from a retrieved one nobody wrote up" do
    output = render("dependencies" => [], "regression_tests" => [])

    expect(output).to include("**widget (yarn) 1.0.0 → 2.0.0** — No behavior-specific note was provided.")
    expect(output).to include("**cgi (bundler) 0.5.1 → 0.5.2** — Upstream delta unavailable")
  end

  # Matching on the manifest's internal `source` enum would cost this raise its note.
  it "attaches a note that did not echo the manifest's source" do
    output = render(
      "dependencies" => [
        { "ecosystem" => "yarn", "name" => "widget", "source" => "registry.npmjs.org",
          "from" => "1.0.0", "to" => "2.0.0", "note" => "The menu changed." },
      ],
      "regression_tests" => []
    )

    expect(output).to include("**widget (yarn) 1.0.0 → 2.0.0** — The menu changed.")
  end

  it "falls back when the response named a version this pull request did not raise" do
    output = render(
      "dependencies" => [
        { "ecosystem" => "yarn", "name" => "widget", "from" => "1.0.0", "to" => "9.9.9", "note" => "Invented." },
      ],
      "regression_tests" => []
    )

    expect(output).to include("**widget (yarn) 1.0.0 → 2.0.0** — No behavior-specific note was provided.")
    expect(output).not_to include("Invented.", "9.9.9")
  end

  it "renders usage-based regression tests and separate application compatibility checks" do
    output = render(
      "dependencies" => [],
      "regression_tests" => [
        { "dependency" => "widget", "title" => "Contact Center menu", "page" => "/contact_center/menu",
          "steps" => ["Open the menu.", "Confirm the selection still persists."] },
      ],
      "application_checks" => [
        { "title" => "Updated menu integration", "page" => "/contact_center/menu",
          "steps" => ["Open the menu.", "Confirm it still renders."] },
      ]
    )

    expect(output).to include("## Regression Testing", "### Contact Center menu")
    expect(output).to include("**Dependency:** widget", "**Page:** /contact_center/menu")
    expect(output).to include("## Application Compatibility Checks", "### Updated menu integration")
    expect(output).not_to include("Applicable Functional Cases")
  end

  # Dropped out loud: a plan publishing fewer cases than were generated reads as complete.
  it "drops a regression test naming an unraised dependency and says so" do
    output = render(
      "dependencies" => [],
      "regression_tests" => [
        { "dependency" => "widget", "title" => "Contact Center menu",
          "steps" => ["Open the menu.", "Confirm it persists."] },
        { "dependency" => "made-up", "title" => "Unrelated page", "steps" => ["Open it.", "Confirm it loads."] },
      ]
    )

    expect(output).to include("1 part of the generated response could not be used")
    expect(output).to include(%(regression test "Unrelated page" named "made-up"))
    expect(output).to include("### Contact Center menu")
    expect(output).not_to include("### Unrelated page")
  end

  it "says plainly when no use could be established" do
    output = render("dependencies" => [], "regression_tests" => [])

    expect(output).to include("## Regression Testing", described_class::NO_REGRESSION_MESSAGE)
    expect(output).not_to include("## Application Compatibility Checks")
  end

  it "carries the dependency-delta warning and counts parser and formatter discards together" do
    output = render(
      {
        "dependencies" => ["not an object"],
        "regression_tests" => [
          { "dependency" => "made-up", "title" => "Unrelated page", "steps" => ["Open it.", "Confirm it loads."] },
        ],
      },
      "Some external dependency evidence is incomplete"
    )

    expect(output).to include("> ⚠️ Some external dependency evidence is incomplete")
    expect(output).to include("2 parts of the generated response could not be used")
    expect(output).to include("> - dependency 1 was not an object")
  end

  it "names the first five discards and counts the rest" do
    output = render("dependencies" => Array.new(7) { "not an object" }, "regression_tests" => [])

    expect(output).to include("7 parts of the generated response could not be used")
    expect(output).to include("> - dependency 5 was not an object")
    expect(output).to include("> - ...and 2 more")
    expect(output).not_to include("> - dependency 6 was not an object")
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
