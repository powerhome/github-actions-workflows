#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "rspec/autorun"
require "tempfile"

require_relative "test_plan_parser"

RSpec.describe TestPlanParser do
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
