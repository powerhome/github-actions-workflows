# frozen_string_literal: true
require_relative "spec_helper"

require "json"
require "open3"
require "tmpdir"

RSpec.describe "bin/render_test_plan.rb" do
  # Read back as UTF-8, not at the locale's encoding: the plan carries the heading's check
  # mark and the arrow between versions, so otherwise this passes or fails on LANG.
  def render(variant:, payload:, dependencies:, expect_success: true)
    Dir.mktmpdir do |directory|
      json_path = File.join(directory, "response.json")
      manifest_path = File.join(directory, "manifest.json")
      comment_path = File.join(directory, "comment.md")
      facts_path = File.join(directory, "facts.json")
      File.write(json_path, JSON.generate(payload), encoding: Encoding::UTF_8)
      File.write(manifest_path, JSON.generate("dependencies" => dependencies), encoding: Encoding::UTF_8)
      File.write(facts_path, JSON.generate("version" => 1, "kits" => {}), encoding: Encoding::UTF_8)

      env = {
        "TEST_PLAN_JSON_PATH" => json_path,
        "TEST_PLAN_COMMENT_PATH" => comment_path,
        "DEPENDENCY_DELTA_MANIFEST_PATH" => manifest_path,
        "PLAYBOOK_KIT_FACTS_PATH" => facts_path,
        "TEST_PLAN_VARIANT" => variant,
        "TEST_PLAN_PROFILE_NAME" => "Cobra Test Plan",
      }
      _stdout, stderr, status = Open3.capture3(env, "ruby", File.join(ACTION_ROOT, "bin", "render_test_plan.rb"))
      next stderr unless expect_success

      expect(status).to be_success, stderr
      File.read(comment_path, encoding: Encoding::UTF_8)
    end
  end

  it "renders every manifest dependency through the dependency variant" do
    output = render(
      variant: "dependency",
      payload: { "dependencies" => [], "regression_tests" => [] },
      dependencies: [
        { "ecosystem" => "yarn", "name" => "widget", "source" => "npm",
          "old_version" => "1.0.0", "new_version" => "2.0.0", "status" => "unavailable" },
      ]
    )

    expect(output).to include("## Dependency version changes", "widget (yarn) 1.0.0 → 2.0.0")
    expect(output).to include("## Regression Testing")
    expect(output).not_to include("## Functional / Features to Test")
  end

  # Failing here throws away every version change the manifest recorded over a key the
  # provider was only ever told to send empty.
  it "renders the dependency variant when the response omits its optional arrays" do
    output = render(
      variant: "dependency",
      payload: { "dependencies" => [] },
      dependencies: [
        { "ecosystem" => "bundler", "name" => "cgi", "source" => "rubygems",
          "old_version" => "0.5.1", "new_version" => "0.5.2", "status" => "retrieved" },
      ]
    )

    expect(output).to include("cgi (bundler) 0.5.1 → 0.5.2", "No behavior-specific note was provided.")
    expect(output).to include("No tester-visible use could be established")
    expect(output).not_to include("## Application Compatibility Checks")
  end

  it "renders a Playbook raise with no changed kit" do
    output = render(
      variant: "playbook",
      payload: { "kits" => [], "regression_tests" => [
        { "title" => "Existing control", "steps" => ["Open it.", "Confirm it still works."] },
      ] },
      dependencies: [
        { "name" => "playbook_ui", "old_version" => "17.0.0", "new_version" => "17.1.0" },
      ]
    )

    expect(output).to include("## Playbook version changes", "playbook_ui 17.0.0 → 17.1.0")
    expect(output).to include("## Additional Playbook Regression Testing", "### Existing control")
  end

  # A shape that never reads the manifest should not fail over it.
  it "renders the standard variant without reading the manifest" do
    output = render(
      variant: "",
      payload: {
        "permissions" => { "required" => "no", "roles" => [], "changes" => [], "subject_actions" => [] },
        "feature_areas" => [
          { "test_path" => "View reminder calls", "domain" => "Contact Center", "code" => "RCH",
            "scenarios" => [
              { "title" => "Reminder calls", "landing_page" => "/contact_center/reminder_calls",
                "steps" => ["Open the page.", "Confirm the list still loads."] },
            ] },
        ],
        "regression_tests" => [],
      },
      dependencies: []
    )

    expect(output).to include("## ✅ Cobra Test Plan", "Reminder calls")
    expect(output).not_to include("## Dependency version changes")
  end

  it "fails with a named variable rather than a stack trace when the manifest path is unset" do
    Dir.mktmpdir do |directory|
      json_path = File.join(directory, "response.json")
      File.write(json_path, JSON.generate("dependencies" => [], "regression_tests" => []), encoding: Encoding::UTF_8)

      _stdout, stderr, status = Open3.capture3(
        {
          "TEST_PLAN_JSON_PATH" => json_path,
          "TEST_PLAN_COMMENT_PATH" => File.join(directory, "comment.md"),
          "PLAYBOOK_KIT_FACTS_PATH" => File.join(directory, "facts.json"),
          "TEST_PLAN_VARIANT" => "dependency",
        },
        "ruby", File.join(ACTION_ROOT, "bin", "render_test_plan.rb")
      )

      expect(status).not_to be_success
      expect(stderr).to include("Missing required environment variable", "DEPENDENCY_DELTA_MANIFEST_PATH")
    end
  end
end
