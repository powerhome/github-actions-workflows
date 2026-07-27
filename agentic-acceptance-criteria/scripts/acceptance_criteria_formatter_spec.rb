#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "rspec/autorun"

require_relative "acceptance_criteria_formatter"
require_relative "acceptance_criteria_parser"

RSpec.describe AcceptanceCriteriaFormatter do
  def parse(payload)
    AcceptanceCriteriaParser.new(payload.to_json)
  end

  def render(payload, title: "Reminder Calls migration")
    described_class.new(
      parsed: parse(payload),
      pull_request_number: "42",
      pull_request_title: title
    ).render
  end

  let(:payload) do
    {
      "permissions" => {
        "required" => "yes",
        "roles" => ["User with Reminder Call History read access"],
      },
      "feature_areas" => [
        {
          "name" => "Reminder Call History",
          "location" => "BASE/contact_center/reminder_calls",
          "code" => "RCH",
          "scenarios" => [
            {
              "title" => "Page load/default results",
              "steps" => [
                "Open Reminder Call History.",
                "Verify the default results display.",
              ],
            },
            {
              "title" => "Project filter",
              "steps" => [
                "Filter by a project number prefix.",
                "Verify unrelated projects are removed.",
              ],
            },
          ],
        },
      ],
      "regression_tests" => [
        {
          "text" => "Verify existing links still work.",
          "details" => ["Project links.", "Recording links."],
        },
      ],
    }
  end

  it "renders the agreed QA hierarchy and deterministic scenario identifiers" do
    expect(render(payload)).to eq(<<~MARKDOWN)
      ## ✅ Test Plan: PR #42 — Reminder Calls migration

      ---

      ### Permissions / Roles

      - **Required Permissions:** Yes
      - **Roles to Test:**
        - User with Reminder Call History read access

      ---

      ### Functional / Features to Test

      #### Reminder Call History — `BASE/contact_center/reminder_calls`

      - **RCH-1 — Page load/default results**
        - Open Reminder Call History.
        - Verify the default results display.

      - **RCH-2 — Project filter**
        - Filter by a project number prefix.
        - Verify unrelated projects are removed.

      ---

      ### Regression Testing

      - Verify existing links still work.
        - Project links.
        - Recording links.
    MARKDOWN
  end

  it "continues numbering when multiple feature areas use the same code" do
    second_area = {
      "name" => "Reminder Call Dashboard",
      "location" => "",
      "code" => "RCH",
      "scenarios" => [
        {
          "title" => "Dashboard navigation",
          "steps" => ["Verify the dashboard opens."],
        },
      ],
    }
    payload["feature_areas"] << second_area

    expect(render(payload)).to include("**RCH-3 — Dashboard navigation**")
  end

  it "renders explicit fallbacks when no manual QA is identified" do
    empty_payload = {
      "permissions" => {
        "required" => "not_identified",
        "roles" => [],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }

    output = render(empty_payload, title: "")

    expect(output).to include("## ✅ Test Plan: PR #42")
    expect(output).to include("**Required Permissions:** Not identified")
    expect(output).to include("**Roles to Test:** Not identified from this change.")
    expect(output).to include("- No manual application QA was identified for this change.")
    expect(output).to include("- No targeted regression testing was identified for this change.")
  end

  it "reports that no special role is needed when permissions are not required" do
    no_permissions_payload = {
      "permissions" => {
        "required" => "no",
        "roles" => [],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }

    expect(render(no_permissions_payload)).to include(
      "**Roles to Test:** No special role required."
    )
  end

  it "normalizes the PR title and removes backticks from locations" do
    payload["feature_areas"].first["location"] = "BASE/`unsafe`"

    output = render(payload, title: "  Search\nmigration  ")

    expect(output).to start_with("## ✅ Test Plan: PR #42 — Search migration")
    expect(output).to include("`BASE/unsafe`")
  end
end
