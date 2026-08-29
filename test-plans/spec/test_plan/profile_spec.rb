require_relative "../spec_helper"
require "test_plan/profile"

require "json"
require "tmpdir"

RSpec.describe TestPlan::Profile do
  let(:action_root) { ACTION_ROOT }

  it "loads the standard Cobra profile without a model override" do
    profile = described_class.load(
      action_root: action_root,
      profile_id: "cobra-test-plan"
    )

    expect(profile.display_name).to eq("Cobra Test Plan")
    expect(profile.model).to eq("")
    expect(profile.comment_tag).to eq("cobra-test-plan")
    expect(profile.prompt_path).to end_with("prompts/cobra_test_plan.md")
  end

  # Cursor bakes the effort tier into the model name; it has no bracketed-option
  # syntax, and rejects an unknown name outright. This spec can only prove the profile
  # says what we meant it to say -- that the name is one Cursor accepts has to be
  # checked against the CLI.
  it "pins the enhanced Cobra profile to Claude Opus 5 at high effort" do
    profile = described_class.load(
      action_root: action_root,
      profile_id: "enhanced-cobra-test-plan"
    )

    expect(profile.model).to eq("claude-opus-5-high")
    expect(profile.comment_tag).to eq("enhanced-cobra-test-plan")
  end

  it "keeps profile comments and artifacts independent while sharing the output contract" do
    standard = described_class.load(action_root: action_root, profile_id: "cobra-test-plan")
    enhanced = described_class.load(action_root: action_root, profile_id: "enhanced-cobra-test-plan")

    expect(enhanced.prompt_path).to eq(standard.prompt_path)
    expect(enhanced.status_comment_tag).not_to eq(standard.status_comment_tag)
    expect(enhanced.failure_comment_tag).not_to eq(standard.failure_comment_tag)
    expect(enhanced.artifact_name).not_to eq(standard.artifact_name)
  end

  it "rejects unknown and path-traversal profile values" do
    expect do
      described_class.load(action_root: action_root, profile_id: "missing")
    end.to raise_error(RuntimeError, /Unknown/)

    expect do
      described_class.load(action_root: action_root, profile_id: "../cobra-test-plan")
    end.to raise_error(RuntimeError, /Invalid/)
  end

  it "rejects prompts outside the action root" do
    Dir.mktmpdir do |directory|
      profiles = File.join(directory, "profiles")
      Dir.mkdir(profiles)
      profile = {
        "id" => "unsafe-plan",
        "display_name" => "Unsafe",
        "prompt" => "../outside.md",
        "model" => "",
        "comment_tag" => "unsafe",
        "status_comment_tag" => "unsafe-status",
        "failure_comment_tag" => "unsafe-failure",
        "artifact_name" => "unsafe-artifact",
      }
      File.write(File.join(directory, "outside.md"), "prompt")
      File.write(File.join(profiles, "unsafe-plan.json"), JSON.generate(profile))

      expect do
        described_class.load(action_root: directory, profile_id: "unsafe-plan")
      end.to raise_error(RuntimeError, /prompt is invalid/)
    end
  end
end
