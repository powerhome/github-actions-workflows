require_relative "../spec_helper"
require "test_plan/parser"

require "json"
require "tempfile"

RSpec.describe TestPlan::Parser do
  def payload(overrides = {})
    {
      "permissions" => {
        "required" => "yes",
        "roles" => ["Dispatcher"],
        "changes" => [],
        "subject_actions" => [
          { "subject" => "Reminder Calls", "action" => "Read" },
        ],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }.merge(overrides)
  end

  it "normalizes and deduplicates permission values" do
    raw = payload(
      "permissions" => {
        "required" => "Not Identified",
        "roles" => ["  Dispatcher\nwith access  ", "Dispatcher with access", ""],
        "changes" => [" Added permission lookup. ", "Added permission lookup."],
        "subject_actions" => [
          { "subject" => " Reminder Calls ", "action" => " Read " },
          { "subject" => "Reminder Calls", "action" => "Read" },
        ],
      }
    )

    expect(described_class.new(raw.to_json).permissions).to eq(
      "required" => "not_identified",
      "roles" => ["Dispatcher with access"],
      "changes" => ["Added permission lookup."],
      "subject_actions" => [{ "subject" => "Reminder Calls", "action" => "Read" }]
    )
  end

  it "records what it could not use instead of dropping it silently" do
    parsed = described_class.new(
      payload(
        "feature_areas" => [
          "not an object",
          { "test_path" => "", "scenarios" => [{ "title" => "x", "steps" => ["a"] }] },
          {
            "test_path" => "Usable",
            "scenarios" => [
              { "title" => "Fine", "steps" => ["Open it.", "Verify it."] },
              { "title" => "No steps", "steps" => [] },
            ],
          },
        ],
        "regression_tests" => ["not an object"]
      ).to_json
    )

    expect(parsed.feature_areas.map { |area| area.fetch("test_path") }).to eq(["Usable"])
    expect(parsed.discarded).to contain_exactly(
      "feature area 1 was not an object",
      "feature area 2 had no test_path",
      "scenario 3.2 (No steps) had no steps",
      "regression test 1 was not an object"
    )
  end

  it "discards a scenario whose steps are not strings" do
    parsed = described_class.new(
      payload(
        "feature_areas" => [
          {
            "test_path" => "Usable",
            "scenarios" => [
              { "title" => "Object step", "steps" => [{ "x" => 1 }] },
              { "title" => "Scalar steps", "steps" => "Open it." },
              { "title" => "Fine", "steps" => ["Open it.", "Verify it."] },
            ],
          },
        ]
      ).to_json
    )

    # Coercion would have published a step reading {"x"=>1}, and turned a bare string
    # into a one-element array the schema never allowed.
    expect(parsed.feature_areas.first.fetch("scenarios").map { |s| s.fetch("title") }).to eq(["Fine"])
    expect(parsed.discarded).to contain_exactly(
      "scenario 1.1 (Object step) had no steps array of strings",
      "scenario 1.2 (Scalar steps) had no steps array of strings"
    )
  end

  it "treats non-string scalars as absent rather than printing them" do
    parsed = described_class.new(
      payload(
        "permissions" => {
          "required" => 1,
          "roles" => ["Real role", 7],
          "changes" => [],
          "subject_actions" => [{ "subject" => 42, "action" => "Read" }],
        },
        "feature_areas" => [
          {
            "test_path" => "Usable",
            "domain" => { "x" => 1 },
            "scenarios" => [
              { "title" => 99, "steps" => ["Open it.", "Verify it."] },
              {
                "title" => "Fine",
                "landing_page" => 5,
                "steps" => ["Open it.", "Verify it."],
              },
            ],
          },
        ],
        "regression_tests" => [{ "text" => { "x" => 1 }, "details" => [] }]
      ).to_json
    )
    scenario = parsed.feature_areas.first.fetch("scenarios").first

    # to_s would have published "42", "99", and Ruby inspect output as plan text.
    expect(parsed.permissions.fetch("required")).to eq("not_identified")
    expect(parsed.permissions.fetch("roles")).to eq(["Real role"])
    expect(parsed.permissions.fetch("subject_actions")).to be_empty
    expect(parsed.feature_areas.first.fetch("domain")).to eq("")
    expect(scenario.fetch("title")).to eq("Fine")
    expect(scenario.fetch("landing_page")).to eq("")
    expect(parsed.regression_tests).to be_empty
    expect(parsed.discarded).to include("scenario 1.1 had no title")
  end

  it "reports nothing discarded for a well-formed response" do
    expect(described_class.new(payload.to_json).discarded).to be_empty
  end

  it "carries a scenario's audience and defaults it to empty" do
    parsed = described_class.new(
      payload(
        "feature_areas" => [
          {
            "test_path" => "Applicant onboarding",
            "code" => "APP",
            "scenarios" => [
              {
                "title" => "Submits an application",
                "audience" => "  Applicant   Portal ",
                "steps" => ["Open the form.", "Verify it submits."],
              },
              {
                "title" => "Internal review",
                "steps" => ["Open the queue.", "Verify it lists the application."],
              },
            ],
          },
        ]
      ).to_json
    )
    scenarios = parsed.feature_areas.first.fetch("scenarios")

    expect(scenarios[0].fetch("audience")).to eq("Applicant Portal")
    expect(scenarios[1].fetch("audience")).to eq("")
  end

  it "normalizes feature areas, scenarios, codes, and regression tests" do
    raw = payload(
      "feature_areas" => [
        {
          "test_path" => " Search ",
          "domain" => " Directory ",
          "code" => "bad-code-value",
          "scenarios" => [
            {
              "title" => " Results ",
              "landing_page" => " /search ",
              "permissions" => [],
              "include_in_regression" => true,
              "steps" => [" Search. ", "Verify results.", "Verify results."],
            },
            { "title" => "No steps", "steps" => [] },
          ],
        },
      ],
      "regression_tests" => [
        { "text" => " Verify links. ", "details" => ["Project links.", "Project links."] },
        { "text" => "Verify links.", "details" => [] },
      ]
    )

    parsed = described_class.new(raw.to_json)
    expect(parsed.feature_areas.first).to include(
      "test_path" => "Search",
      "domain" => "Directory",
      "code" => "AC"
    )
    expect(parsed.feature_areas.first["scenarios"].first["steps"]).to eq(["Search.", "Verify results."])
    expect(parsed.regression_tests).to eq(
      [{ "text" => "Verify links.", "details" => ["Project links."] }]
    )
  end

  it "recovers JSON from fences and surrounding prose" do
    expect(described_class.new("```json\n#{payload.to_json}\n```").permissions["required"]).to eq("yes")
    expect(described_class.new("Plan:\n#{payload.to_json}\nDone").permissions["roles"]).to eq(["Dispatcher"])
  end

  it "reads a response from disk" do
    Tempfile.create(["test-plan", ".json"]) do |file|
      file.write(payload.to_json)
      file.flush
      expect(described_class.parse_file(file.path).permissions["required"]).to eq("yes")
    end
  end

  it "requires the documented root shape" do
    expect { described_class.new("[]") }.to raise_error(RuntimeError, /JSON object/)
    expect do
      described_class.new({ "feature_areas" => [], "regression_tests" => [] }.to_json)
    end.to raise_error(RuntimeError, /permissions/)

    raw = payload
    raw["permissions"].delete("subject_actions")
    expect { described_class.new(raw.to_json) }.to raise_error(RuntimeError, /subject_actions/)
  end

  it "uses not_identified for unsupported permission values" do
    raw = payload
    raw["permissions"]["required"] = "maybe"
    expect(described_class.new(raw.to_json).permissions["required"]).to eq("not_identified")
  end

  it "requires all permission collection fields" do
    %w[roles changes subject_actions].each do |field|
      raw = payload
      raw["permissions"].delete(field)
      expect { described_class.new(raw.to_json) }.to raise_error(RuntimeError, /#{field}/)
    end
  end

  it "requires root collection fields to be arrays" do
    expect do
      described_class.new(payload("feature_areas" => "none").to_json)
    end.to raise_error(RuntimeError, /feature_areas/)

    expect do
      described_class.new(payload("regression_tests" => "none").to_json)
    end.to raise_error(RuntimeError, /regression_tests/)
  end
end
