#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "rspec/autorun"
require "tempfile"

require_relative "acceptance_criteria_parser"

RSpec.describe AcceptanceCriteriaParser do
  def payload(overrides = {})
    {
      "permissions" => {
        "required" => "yes",
        "roles" => ["Dispatcher"],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }.merge(overrides)
  end

  describe "#permissions" do
    it "normalizes permission values and deduplicates roles" do
      raw = payload(
        "permissions" => {
          "required" => "Not Identified",
          "roles" => ["  Dispatcher\nwith access  ", "Dispatcher with access", "", nil],
        }
      )

      parsed = described_class.new(raw.to_json)

      expect(parsed.permissions).to eq(
        "required" => "not_identified",
        "roles" => ["Dispatcher with access"]
      )
    end

    it "uses not_identified for an unsupported permission value" do
      raw = payload("permissions" => { "required" => "maybe", "roles" => [] })
      expect(described_class.new(raw.to_json).permissions["required"]).to eq("not_identified")
    end
  end

  describe "#feature_areas" do
    it "normalizes feature areas and discards empty scenarios" do
      raw = payload(
        "feature_areas" => [
          {
            "name" => " Reminder Call History ",
            "location" => " BASE/contact_center/reminder_calls ",
            "code" => "rch",
            "scenarios" => [
              {
                "title" => " Page load ",
                "steps" => [
                  "Open the page.",
                  " Verify default results. ",
                  "Verify default results.",
                  "",
                ],
              },
              { "title" => "No steps", "steps" => [] },
            ],
          },
          {
            "name" => "Empty area",
            "code" => "EA",
            "scenarios" => [],
          },
        ]
      )

      parsed = described_class.new(raw.to_json)

      expect(parsed.feature_areas).to eq(
        [
          {
            "name" => "Reminder Call History",
            "location" => "BASE/contact_center/reminder_calls",
            "code" => "RCH",
            "scenarios" => [
              {
                "title" => "Page load",
                "steps" => ["Open the page.", "Verify default results."],
              },
            ],
          },
        ]
      )
    end

    it "falls back to AC when the feature code is invalid" do
      raw = payload(
        "feature_areas" => [
          {
            "name" => "Search",
            "location" => "",
            "code" => "too-long-code",
            "scenarios" => [{ "title" => "Filter", "steps" => ["Verify filtering."] }],
          },
        ]
      )

      expect(described_class.new(raw.to_json).feature_areas.first["code"]).to eq("AC")
    end
  end

  describe "#regression_tests" do
    it "normalizes and deduplicates regression tests and their details" do
      raw = payload(
        "regression_tests" => [
          {
            "text" => " Verify links still work. ",
            "details" => ["Project links.", " Project links. ", "Recording links."],
          },
          { "text" => "Verify links still work.", "details" => [] },
          { "text" => "", "details" => [] },
        ]
      )

      expect(described_class.new(raw.to_json).regression_tests).to eq(
        [
          {
            "text" => "Verify links still work.",
            "details" => ["Project links.", "Recording links."],
          },
        ]
      )
    end
  end

  describe ".parse_file" do
    it "reads JSON from disk" do
      Tempfile.create(["acceptance-criteria", ".json"]) do |file|
        file.write(payload.to_json)
        file.flush

        expect(described_class.parse_file(file.path).permissions["required"]).to eq("yes")
      end
    end
  end

  describe "JSON extraction" do
    it "parses JSON wrapped in fences" do
      parsed = described_class.new("```json\n#{payload.to_json}\n```")
      expect(parsed.permissions["roles"]).to eq(["Dispatcher"])
    end

    it "extracts JSON surrounded by prose" do
      parsed = described_class.new("Here is the plan:\n#{payload.to_json}\nDone.")
      expect(parsed.permissions["required"]).to eq("yes")
    end
  end

  describe "validation" do
    it "rejects a non-object root" do
      expect { described_class.new("[]") }.to raise_error(RuntimeError, /JSON object/)
    end

    it "requires the permissions object" do
      expect do
        described_class.new(
          { "feature_areas" => [], "regression_tests" => [] }.to_json
        )
      end.to raise_error(RuntimeError, /permissions/)
    end

    it "requires root collection fields to be arrays" do
      expect do
        described_class.new(
          payload("feature_areas" => "none").to_json
        )
      end.to raise_error(RuntimeError, /feature_areas/)
    end
  end
end
