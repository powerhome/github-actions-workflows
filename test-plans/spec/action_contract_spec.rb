# frozen_string_literal: true
require_relative "spec_helper"

require "yaml"

RSpec.describe "test-plans/action.yml" do
  let(:action_path) { File.join(ACTION_ROOT, "action.yml") }
  let(:action) { YAML.safe_load_file(action_path, aliases: true) }
  let(:steps) { action.fetch("runs").fetch("steps") }

  it "exposes profiles but not caller-controlled prompts or models" do
    inputs = action.fetch("inputs")
    expect(inputs).to include("profile", "provider-api-key", "pull-request-number")
    expect(inputs).not_to include("additional-prompt", "model")
  end

  it "checks mergeability before checkout, dependency retrieval, or provider usage" do
    names = steps.map { |step| step.fetch("name") }
    preflight_index = names.index("Check pull request mergeability")

    expect(preflight_index).to be < names.index("Check out repository")
    expect(preflight_index).to be < names.index("Build dependency evidence with Ruby")
    expect(preflight_index).to be < names.index("AI: Generate test-plan JSON")
  end

  it "gates every generation step on the mergeability result" do
    generation_names = [
      "Post in-progress status comment",
      "Check out repository",
      "Clear generated output paths",
      "Fetch base commit",
      "Fetch through merge-base",
      "Remove Git credentials from the workspace",
      "Compute PR diff",
      "Build dependency evidence with Ruby",
      "Select AI prompt from evidence",
      "Reset agent instructions to the merge base",
      "AI: Generate test-plan JSON",
      "Upload test-plan artifacts",
      "Ruby: Validate AI response and render comment",
      "Upsert test-plan comment",
      "Clear in-progress status comment",
    ]
    generation_steps = steps.select { |step| generation_names.include?(step.fetch("name")) }

    expect(generation_steps.length).to eq(generation_names.length)
    generation_steps.each do |step|
      expect(step.fetch("if", "")).to include("pr_metadata.outputs.generate == 'true'")
    end
  end

  it "clears a stale failure comment on both terminal paths with one step" do
    clearing = steps.select do |step|
      step.dig("env", "COMMENT_MODE") == "delete" &&
        step.dig("env", "COMMENT_TAG").to_s.include?("failure_comment_tag")
    end
    expect(clearing.length).to eq(1)

    condition = clearing.first.fetch("if")
    expect(condition).to include("pr_metadata.outputs.blocked == 'true'")
    expect(condition).to include("pr_metadata.outputs.generate == 'true'")
  end

  it "resets pull-request-supplied agent instructions before any provider reads them" do
    names = steps.map { |step| step.fetch("name") }
    reset_index = names.index("Reset agent instructions to the merge base")

    # Needs the merge base, so it has to follow the merge-base fetch.
    expect(reset_index).to be > names.index("Fetch through merge-base")
    expect(reset_index).to be < names.index("AI: Generate test-plan JSON")
  end

  it "leaves model selection to the provider" do
    provider_step = steps.find { |step| step.fetch("name") == "AI: Generate test-plan JSON" }
    expect(provider_step.fetch("env")).not_to have_key("MODEL")
  end

  it "keeps the provider call between deterministic evidence assembly and rendering" do
    names = steps.map { |step| step.fetch("name") }
    ai_index = names.index("AI: Generate test-plan JSON")

    expect(ai_index).to be > names.index("Select AI prompt from evidence")
    expect(ai_index).to be > names.index("Reset agent instructions to the merge base")
    expect(ai_index).to be < names.index("Ruby: Validate AI response and render comment")
    expect(steps[ai_index].fetch("run")).to include("/ai/providers/${provider}.sh")
    expect(steps.count { |step| step.fetch("run", "").include?("/ai/providers/") }).to eq(1)
  end
end
