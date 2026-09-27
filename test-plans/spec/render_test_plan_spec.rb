require_relative "spec_helper"

require "json"
require "open3"
require "tmpdir"

RSpec.describe "bin/render_test_plan.rb" do
  def render(variant:, payload:, dependencies:)
    Dir.mktmpdir do |directory|
      json_path = File.join(directory, "response.json")
      manifest_path = File.join(directory, "manifest.json")
      comment_path = File.join(directory, "comment.md")
      facts_path = File.join(directory, "facts.json")
      File.write(json_path, JSON.generate(payload))
      File.write(manifest_path, JSON.generate("dependencies" => dependencies))
      File.write(facts_path, JSON.generate("version" => 1, "kits" => {}))

      env = {
        "TEST_PLAN_JSON_PATH" => json_path,
        "TEST_PLAN_COMMENT_PATH" => comment_path,
        "DEPENDENCY_DELTA_MANIFEST_PATH" => manifest_path,
        "PLAYBOOK_KIT_FACTS_PATH" => facts_path,
        "TEST_PLAN_VARIANT" => variant,
        "TEST_PLAN_PROFILE_NAME" => "Cobra Test Plan",
      }
      _stdout, stderr, status = Open3.capture3(env, "ruby", File.join(ACTION_ROOT, "bin", "render_test_plan.rb"))
      expect(status).to be_success, stderr
      File.read(comment_path)
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
end
