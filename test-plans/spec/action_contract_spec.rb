# frozen_string_literal: true

require_relative "spec_helper"

require "yaml"

RSpec.describe "test-plans/action.yml" do
  let(:action_path) { File.join(ACTION_ROOT, "action.yml") }
  let(:action) { YAML.safe_load_file(action_path, aliases: true) }
  let(:steps) { action.fetch("runs").fetch("steps") }

  it "exposes profiles, a model, and Claude args but not caller-controlled prompts" do
    inputs = action.fetch("inputs")
    expect(inputs).to include("profile", "provider-api-key", "pull-request-number", "model", "claude-args")
    expect(inputs.fetch("model").fetch("default")).to eq("")
    expect(inputs.fetch("claude-args").fetch("default")).to eq("")
    expect(inputs).not_to include("additional-prompt")
  end

  it "checks mergeability before checkout, dependency retrieval, or provider usage" do
    names = steps.map { |step| step.fetch("name") }
    preflight_index = names.index("Check pull request mergeability")

    expect(preflight_index).to be < names.index("Check out repository")
    expect(preflight_index).to be < names.index("Build external dependency delta")
    expect(preflight_index).to be < names.index("Run test-plan provider")
  end

  it "gates every generation step on the mergeability result" do
    generation_step_names = Regexp.union(
      [
        "Check out", "agent instructions", "Fetch base", "Fetch through", "Compute PR diff",
        "dependency delta", "provider", "Render test-plan", "Upsert test-plan"
      ]
    )
    generation_steps = steps.select { |step| step.fetch("name").match?(generation_step_names) }

    expect(generation_steps).not_to be_empty
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
    expect(reset_index).to be < names.index("Run test-plan provider")
  end

  # A composite step inherits the caller's job env, so these are set rather than omitted.
  it "takes the caller's model, else pins Cursor's, and takes the caller's Claude args but not its settings" do
    provider_step = steps.find { |step| step.fetch("name") == "Run test-plan provider" }
    env = provider_step.fetch("env")

    expect(env.fetch("MODEL")).to start_with("${{ inputs.model || ")
    expect(env.fetch("MODEL")).to include("inputs.provider == 'cursor'", "claude-sonnet-5-5-high")
    expect(env.fetch("CLAUDE_ARGS")).to eq("${{ inputs.claude-args }}")
    expect(env.fetch("CLAUDE_SETTINGS")).to eq("")
  end
end
