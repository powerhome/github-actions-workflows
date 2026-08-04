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
      pull_request_title: title
    ).render
  end

  let(:payload) do
    {
      "permissions" => {
        "required" => "yes",
        "roles" => ["User with Reminder Call History read access"],
        "changes" => ["Added permission lookup: Reminder Calls — Read."],
        "subject_actions" => [
          { "subject" => "Reminder Calls", "action" => "Read" },
          { "subject" => "Projects", "action" => "Read" },
        ],
      },
      "feature_areas" => [
        {
          "test_path" => "View and filter reminder call history",
          "domain" => "Contact Center",
          "code" => "RCH",
          "scenarios" => [
            {
              "title" => "Page load/default results",
              "landing_page" => "/contact_center/reminder_calls",
              "permissions" => [
                { "subject" => "Reminder Calls", "action" => "Read" },
              ],
              "include_in_regression" => true,
              "steps" => [
                "Open Reminder Call History.",
                "Verify the default results display.",
              ],
            },
            {
              "title" => "Project filter",
              "landing_page" => "/contact_center/reminder_calls",
              "permissions" => [
                { "subject" => "Reminder Calls", "action" => "Read" },
                { "subject" => "Projects", "action" => "Read" },
              ],
              "include_in_regression" => false,
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
      ## ✅ Test Plan: Reminder Calls migration

      ---

      ## Permissions / Roles

      - **Required Permissions:** Yes
      - **Permission Changes in This PR:**
        - Added permission lookup: Reminder Calls — Read.
      - **Roles to Test:**
        - User with Reminder Call History read access
      - **Permission Subjects / Actions:**
        - Reminder Calls — Read
        - Projects — Read

      ---

      ## Functional / Features to Test

      ### View and filter reminder call history — Contact Center

      #### RCH-1 — Page load/default results

      **Landing Page:** /contact_center/reminder_calls#{'  '}
      **Permissions:** Reminder Calls — Read

      - Open Reminder Call History.
      - Verify the default results display.

      #### RCH-2 — Project filter

      **Landing Page:** /contact_center/reminder_calls#{'  '}
      **Permissions:** Reminder Calls — Read; Projects — Read

      - Filter by a project number prefix.
      - Verify unrelated projects are removed.

      ---

      ## Regression Testing

      - **Applicable Functional Cases:** RCH-1

      - Verify existing links still work.
        - Project links.
        - Recording links.
    MARKDOWN
  end

  it "continues numbering when multiple feature areas use the same code" do
    second_area = {
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
    payload["feature_areas"] << second_area

    expect(render(payload)).to include("#### RCH-3 — Dashboard navigation")
  end

  it "renders explicit fallbacks when no manual QA is identified" do
    empty_payload = {
      "permissions" => {
        "required" => "not_identified",
        "roles" => [],
        "changes" => [],
        "subject_actions" => [],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }

    output = render(empty_payload, title: "")

    expect(output).to include("## ✅ Test Plan")
    expect(output).to include("**Required Permissions:** Not identified")
    expect(output).to include("**Roles to Test:** Not identified from this change.")
    expect(output).to include("**Permission Subjects / Actions:** Not identified from this change.")
    expect(output).to include("- No manual application QA was identified for this change.")
    expect(output).to include("- No targeted regression testing was identified for this change.")
  end

  it "reports that no special role is needed when permissions are not required" do
    no_permissions_payload = {
      "permissions" => {
        "required" => "no",
        "roles" => [],
        "changes" => [],
        "subject_actions" => [],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }

    expect(render(no_permissions_payload)).to include(
      "**Roles to Test:** No special role required."
    )
    expect(render(no_permissions_payload)).to include(
      "**Permission Subjects / Actions:** No special permission required."
    )
  end

  it "renders per-case permission fallbacks as standalone metadata" do
    payload["feature_areas"].first["scenarios"].first["permissions"] = []

    expect(render(payload)).to include(
      "**Landing Page:** /contact_center/reminder_calls  \n**Permissions:** Not identified for this case.\n\n- Open Reminder Call History."
    )

    payload["permissions"]["required"] = "no"

    expect(render(payload)).to include(
      "**Permissions:** No special permission required.\n\n- Open Reminder Call History."
    )
  end

  it "renders Consent permissions with the matching UI subject and titleized action" do
    payload["permissions"]["subject_actions"] = [
      { "subject" => "Project Items", "action" => "Edit Comments" },
      { "subject" => "Projects", "action" => "Edit Items For Closed Project" },
    ]
    payload["feature_areas"].first["scenarios"].first["permissions"] = [
      { "subject" => "Project Items", "action" => "Edit Comments" },
    ]

    output = render(payload)

    expect(output).to include("- Project Items — Edit Comments")
    expect(output).to include("- Projects — Edit Items For Closed Project")
    expect(output).to include("**Permissions:** Project Items — Edit Comments")
    expect(output).not_to include("ProjectItem")
    expect(output).not_to include("edit_comments")
  end

  it "calls out permission changes and removes backticks from their text" do
    payload["permissions"]["changes"] = [
      "Added permission: `Project Items` — `Edit Comments`.",
      "Modified permission lookup: Projects — Edit Items For Closed Project.",
    ]

    output = render(payload)

    expect(output).to include(<<~MARKDOWN.chomp)
      - **Permission Changes in This PR:**
        - Added permission: Project Items — Edit Comments.
        - Modified permission lookup: Projects — Edit Items For Closed Project.
    MARKDOWN
  end

  it "normalizes the PR title and removes backticks from paths and permission labels" do
    payload["feature_areas"].first["scenarios"].first["landing_page"] = "/`unsafe`"
    payload["permissions"]["subject_actions"].first["subject"] = "`Reminder Calls`"
    payload["permissions"]["subject_actions"].first["action"] = "`Read`"
    payload["feature_areas"].first["scenarios"].first["permissions"].first["subject"] = "`Reminder Calls`"
    payload["feature_areas"].first["scenarios"].first["permissions"].first["action"] = "`Read`"

    output = render(payload, title: "  Search\nmigration  ")

    expect(output).to start_with("## ✅ Test Plan: Search migration")
    expect(output).not_to include("PR #")
    expect(output).to include("**Landing Page:** /unsafe")
    expect(output).to include("- Reminder Calls — Read")
    expect(output).to include("**Permissions:** Reminder Calls — Read")
    expect(output).not_to include("`")
  end

  it "lists only functional identifiers when regressions are fully covered by functional cases" do
    payload["feature_areas"].first["scenarios"].last["include_in_regression"] = true
    payload["regression_tests"] = []

    regression_section = render(payload).split("## Regression Testing", 2).last

    expect(regression_section).to include("**Applicable Functional Cases:** RCH-1, RCH-2")
    expect(regression_section).not_to include("Page load/default results")
    expect(regression_section).not_to include("Project filter")
  end
end
