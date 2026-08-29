require_relative "../spec_helper"
require "test_plan/formatter"
require "test_plan/parser"

require "json"

RSpec.describe TestPlan::Formatter do
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
      parsed: TestPlan::Parser.new(payload.to_json),
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

  it "names the audience between the landing page and the permissions" do
    payload["feature_areas"][0]["scenarios"][0]["audience"] = "Applicant Portal"

    expect(render).to include(
      "**Landing Page:** /contact_center/reminder_calls  \n" \
      "**Audience:** Applicant Portal  \n" \
      "**Permissions:** Reminder Calls — Read"
    )
  end

  it "omits the audience line for a single-audience application" do
    output = render

    expect(output).not_to include("**Audience:**")
    expect(output).to include("**Landing Page:** /contact_center/reminder_calls  \n**Permissions:**")
  end

  it "keeps an audience while reporting that no permission is required" do
    payload["permissions"]["required"] = "no"
    payload["permissions"]["subject_actions"] = []
    payload["feature_areas"][0]["scenarios"][0]["permissions"] = []
    payload["feature_areas"][0]["scenarios"][0]["audience"] = "Customer Portal"

    output = render

    # An external customer has no Consent subject; the audience still has to be stated.
    expect(output).to include("**Audience:** Customer Portal")
    expect(output).to include("**Permissions:** No special permission required.")
  end

  it "neutralizes mentions, links, and HTML in provider text" do
    scenario = payload["feature_areas"][0]["scenarios"][0]
    scenario["title"] = "Ping @powerhome/heroes-for-hire"
    scenario["steps"] = [
      "Open [the page](https://example.test/phish).",
      "Verify <img src=x onerror=alert(1)> renders nothing.",
    ]
    payload["permissions"]["roles"] = ["Role for @someone"]
    payload["regression_tests"] = [{ "text" => "Ask @another to confirm.", "details" => [] }]

    output = render

    expect(output).not_to include("@powerhome", "@someone", "@another")
    expect(output).to include("&#64;powerhome/heroes-for-hire")
    # The link and the tag survive as readable text without being live.
    expect(output).to include("\\[the page\\]")
    expect(output).to include("&lt;img src=x onerror=alert(1)&gt;")
    expect(output).not_to include("<img")
  end

  it "neutralizes a pull-request title the author controls" do
    described = described_class.new(
      parsed: TestPlan::Parser.new(payload.to_json),
      pull_request_title: "Fix for @everyone <b>now</b>",
      profile_name: "Cobra Test Plan",
      generation_warning: ""
    ).render

    expect(described).to include("&#64;everyone &lt;b&gt;now&lt;/b&gt;")
    expect(described).not_to include("@everyone")
  end

  it "leaves ordinary text alone" do
    payload["feature_areas"][0]["scenarios"][0]["steps"] = ["Open the R&D page.", "Verify it loads."]

    output = render

    expect(output).to include("Open the R&amp;D page.")
    expect(output).to include("- Verify it loads.")
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
