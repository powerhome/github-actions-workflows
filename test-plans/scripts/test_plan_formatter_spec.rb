#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "rspec/autorun"

require_relative "test_plan_formatter"
require_relative "test_plan_parser"

RSpec.describe TestPlanFormatter do
  let(:payload) do
    {
      "permissions" => {
        "required" => "yes",
        "roles" => ["User with access"],
        "changes" => ["Added permission lookup: Reminder Calls — Read."],
        "subject_actions" => [{ "subject" => "Reminder Calls", "action" => "Read" }],
      },
      "feature_areas" => [
        {
          "test_path" => "View reminder calls",
          "domain" => "Contact Center",
          "code" => "RCH",
          "scenarios" => [
            {
              "title" => "Default results",
              "landing_page" => "/contact_center/reminder_calls",
              "permissions" => [{ "subject" => "Reminder Calls", "action" => "Read" }],
              "include_in_regression" => true,
              "steps" => ["Open the page.", "Verify default results."],
            },
          ],
        },
      ],
      "regression_tests" => [{ "text" => "Verify existing links.", "details" => [] }],
    }
  end

  def render(profile: "Cobra Test Plan", warning: "")
    described_class.new(
      parsed: TestPlanParser.new(payload.to_json),
      pull_request_title: "Reminder Calls migration",
      profile_name: profile,
      generation_warning: warning
    ).render
  end

  it "renders the profile-specific hierarchy and deterministic case identifiers" do
    output = render
    expect(output).to start_with("## ✅ Cobra Test Plan: Reminder Calls migration")
    expect(output).to include("## Permissions / Roles")
    expect(output).to include("### View reminder calls — Contact Center")
    expect(output).to include("#### RCH-1 — Default results")
    expect(output).to include("**Landing Page:** /contact_center/reminder_calls  \n**Permissions:** Reminder Calls — Read")
    expect(output).to include("**Applicable Functional Cases:** RCH-1")
  end

  it "renders dependency warnings directly below the heading" do
    output = render(warning: "Some dependency deltas were unavailable.")
    expect(output).to start_with(<<~MARKDOWN.chomp)
      ## ✅ Cobra Test Plan: Reminder Calls migration

      > ⚠️ Some dependency deltas were unavailable.
    MARKDOWN
  end

  it "uses the enhanced profile name without changing the body format" do
    output = render(profile: "Enhanced Cobra Test Plan")
    expect(output).to start_with("## ✅ Enhanced Cobra Test Plan")
    expect(output).to include("#### RCH-1 — Default results")
  end

  it "renders explicit no-QA and permission fallbacks" do
    payload["permissions"] = {
      "required" => "not_identified",
      "roles" => [],
      "changes" => [],
      "subject_actions" => [],
    }
    payload["feature_areas"] = []
    payload["regression_tests"] = []

    output = render
    expect(output).to include("**Required Permissions:** Not identified")
    expect(output).to include("No manual application QA was identified")
    expect(output).to include("No targeted regression testing was identified")
  end

  it "continues numbering when feature areas share a case code" do
    payload["feature_areas"] << {
      "test_path" => "Open the reminder call dashboard",
      "domain" => "Contact Center",
      "code" => "RCH",
      "scenarios" => [
        {
          "title" => "Dashboard navigation",
          "landing_page" => "/contact_center",
          "permissions" => [],
          "include_in_regression" => false,
          "steps" => ["Verify the dashboard opens."],
        },
      ],
    }

    expect(render).to include("#### RCH-2 — Dashboard navigation")
  end

  it "reports that no special role or permission is needed" do
    payload["permissions"] = {
      "required" => "no",
      "roles" => [],
      "changes" => [],
      "subject_actions" => [],
    }

    output = render
    expect(output).to include("**Roles to Test:** No special role required.")
    expect(output).to include("**Permission Subjects / Actions:** No special permission required.")
  end

  it "renders per-case permission fallbacks as standalone metadata" do
    payload["feature_areas"].first["scenarios"].first["permissions"] = []
    expect(render).to include(
      "**Landing Page:** /contact_center/reminder_calls  \n**Permissions:** Not identified for this case.\n\n- Open the page."
    )

    payload["permissions"]["required"] = "no"
    expect(render).to include(
      "**Permissions:** No special permission required.\n\n- Open the page."
    )
  end

  it "keeps Consent UI labels while stripping Markdown backticks" do
    payload["permissions"]["changes"] = ["Added permission: `Project Items` — `Edit Comments`."]
    payload["permissions"]["subject_actions"] = [
      { "subject" => "`Project Items`", "action" => "`Edit Comments`" },
    ]
    scenario = payload["feature_areas"].first["scenarios"].first
    scenario["landing_page"] = "/`unsafe`"
    scenario["permissions"] = [
      { "subject" => "`Project Items`", "action" => "`Edit Comments`" },
    ]

    output = render
    expect(output).to include("Added permission: Project Items — Edit Comments.")
    expect(output).to include("**Landing Page:** /unsafe")
    expect(output).to include("**Permissions:** Project Items — Edit Comments")
    expect(output).not_to include("`")
  end

  it "lists only functional identifiers for regressions covered by cases" do
    payload["regression_tests"] = []
    regression_section = render.split("## Regression Testing", 2).last

    expect(regression_section).to include("**Applicable Functional Cases:** RCH-1")
    expect(regression_section).not_to include("Default results")
  end
end
