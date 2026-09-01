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

  it "rejects a definition whose declared id is not the one requested" do
    Dir.mktmpdir do |directory|
      profiles = File.join(directory, "profiles")
      Dir.mkdir(profiles)
      Dir.mkdir(File.join(directory, "prompts"))
      File.write(File.join(directory, "prompts", "plan.md"), "prompt")
      File.write(
        File.join(profiles, "requested-plan.json"),
        JSON.generate(
          "id" => "some-other-plan",
          "display_name" => "Mismatched",
          "prompt" => "prompts/plan.md",
          "model" => "",
          "comment_tag" => "mismatched",
          "status_comment_tag" => "mismatched-status",
          "failure_comment_tag" => "mismatched-failure",
          "artifact_name" => "mismatched-artifact"
        )
      )

      # The blocked message names this id as the label to reapply, so a mismatch would
      # send the author after a label that does not exist.
      expect do
        described_class.load(action_root: directory, profile_id: "requested-plan")
      end.to raise_error(RuntimeError, /declares a different id/)
    end
  end

  it "has no Playbook prompt unless the profile declares one" do
    profile = TestPlan::Profile.load(action_root: ACTION_ROOT, profile_id: "cobra-test-plan")

    expect(profile.playbook_prompt_path).to eq("")
    expect(profile.to_h).to have_key("playbook_prompt_path")
  end

  it "resolves a declared Playbook prompt" do
    Dir.mktmpdir do |directory|
      Dir.mkdir(File.join(directory, "prompts"))
      Dir.mkdir(File.join(directory, "profiles"))
      File.write(File.join(directory, "prompts", "plan.md"), "prompt")
      File.write(File.join(directory, "prompts", "playbook.md"), "playbook prompt")
      File.write(
        File.join(directory, "profiles", "sample.json"),
        JSON.generate(
          "id" => "sample", "display_name" => "Sample", "prompt" => "prompts/plan.md",
          "playbook_prompt" => "prompts/playbook.md", "model" => "",
          "comment_tag" => "sample", "status_comment_tag" => "sample-status",
          "failure_comment_tag" => "sample-failure", "artifact_name" => "sample-artifacts"
        )
      )

      profile = TestPlan::Profile.load(action_root: directory, profile_id: "sample")

      expect(profile.playbook_prompt_path).to end_with("prompts/playbook.md")
    end
  end

  # Same containment rule as the main prompt: the variant is a path from a profile
  # definition and must not reach outside the action.
  it "rejects a Playbook prompt outside the action root" do
    Dir.mktmpdir do |directory|
      Dir.mkdir(File.join(directory, "prompts"))
      Dir.mkdir(File.join(directory, "profiles"))
      File.write(File.join(directory, "prompts", "plan.md"), "prompt")
      File.write(File.join(directory, "outside.md"), "prompt")
      File.write(
        File.join(directory, "profiles", "sample.json"),
        JSON.generate(
          "id" => "sample", "display_name" => "Sample", "prompt" => "prompts/plan.md",
          "playbook_prompt" => "../outside.md", "model" => "",
          "comment_tag" => "sample", "status_comment_tag" => "sample-status",
          "failure_comment_tag" => "sample-failure", "artifact_name" => "sample-artifacts"
        )
      )

      expect do
        TestPlan::Profile.load(action_root: directory, profile_id: "sample")
      end.to raise_error(RuntimeError, /playbook_prompt is invalid/)
    end
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
