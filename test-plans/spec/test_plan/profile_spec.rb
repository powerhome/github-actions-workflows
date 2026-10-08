# frozen_string_literal: true

require_relative "../spec_helper"
require "test_plan/profile"

require "json"
require "tmpdir"

RSpec.describe TestPlan::Profile do
  let(:action_root) { ACTION_ROOT }

  it "loads the Cobra profile" do
    profile = described_class.load(
      action_root:,
      profile_id: "cobra-test-plan"
    )

    expect(profile.display_name).to eq("Cobra Test Plan")
    expect(profile.comment_tag).to eq("cobra-test-plan")
    expect(profile.prompt_path).to end_with("prompts/cobra_test_plan.md")
  end

  it "reads Consent permissions when a profile declares no access" do
    profile = described_class.load(action_root:, profile_id: "cobra-test-plan")

    expect(profile.access).to eq("consent")
    expect(profile.to_h.fetch("access")).to eq("consent")
  end

  it "rejects an access it does not know" do
    Dir.mktmpdir do |directory|
      Dir.mkdir(File.join(directory, "profiles"))
      Dir.mkdir(File.join(directory, "prompts"))
      File.write(File.join(directory, "prompts", "plan.md"), "prompt")
      File.write(
        File.join(directory, "profiles", "odd-plan.json"),
        JSON.generate(
          "id" => "odd-plan",
          "display_name" => "Odd",
          "access" => "roles",
          "prompt" => "prompts/plan.md",
          "comment_tag" => "odd",
          "status_comment_tag" => "odd-status",
          "failure_comment_tag" => "odd-failure",
          "artifact_name" => "odd-artifact"
        )
      )

      expect do
        described_class.load(action_root: directory, profile_id: "odd-plan")
      end.to raise_error(RuntimeError, /access must be one of consent, sign_in/)
    end
  end

  it "rejects unknown and path-traversal profile values" do
    expect do
      described_class.load(action_root:, profile_id: "missing")
    end.to raise_error(RuntimeError, /Unknown/)

    expect do
      described_class.load(action_root:, profile_id: "../cobra-test-plan")
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

  it "resolves the Playbook prompt the Cobra profile declares" do
    profile = TestPlan::Profile.load(action_root: ACTION_ROOT, profile_id: "cobra-test-plan")

    expect(profile.playbook_prompt_path).to end_with("prompts/cobra_playbook_test_plan.md")
    expect(profile.dependency_prompt_path).to end_with("prompts/cobra_dependency_test_plan.md")
    expect(profile.to_h).to have_key("playbook_prompt_path")
    expect(profile.to_h).to have_key("dependency_prompt_path")
  end

  it "has no Playbook prompt when a profile declares none" do
    Dir.mktmpdir do |directory|
      Dir.mkdir(File.join(directory, "prompts"))
      Dir.mkdir(File.join(directory, "profiles"))
      File.write(File.join(directory, "prompts", "plan.md"), "prompt")
      File.write(
        File.join(directory, "profiles", "sample.json"),
        JSON.generate(
          "id" => "sample", "display_name" => "Sample", "prompt" => "prompts/plan.md",
          "comment_tag" => "sample", "status_comment_tag" => "sample-status",
          "failure_comment_tag" => "sample-failure", "artifact_name" => "sample-artifacts"
        )
      )

      expect(TestPlan::Profile.load(action_root: directory, profile_id: "sample").playbook_prompt_path).to eq("")
    end
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
          "playbook_prompt" => "prompts/playbook.md",
          "comment_tag" => "sample", "status_comment_tag" => "sample-status",
          "failure_comment_tag" => "sample-failure", "artifact_name" => "sample-artifacts"
        )
      )

      profile = TestPlan::Profile.load(action_root: directory, profile_id: "sample")

      expect(profile.playbook_prompt_path).to end_with("prompts/playbook.md")
    end
  end

  # Same containment rule as the main prompt.
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
          "playbook_prompt" => "../outside.md",
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
