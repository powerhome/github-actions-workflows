require_relative "../spec_helper"
require "test_plan/variant"

RSpec.describe TestPlan::Variant do
  let(:paths) do
    {
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "/action/prompts/cobra_playbook_test_plan.md",
      dependency_prompt_path: "/action/prompts/cobra_dependency_test_plan.md",
    }
  end

  it "selects Playbook for a raise even without changed kits or with application edits" do
    expect(described_class.select(**paths, playbook_raised: true, change_count: 2)).to eq(
      "name" => "playbook", "prompt_path" => paths.fetch(:playbook_prompt_path)
    )
  end

  it "selects the dependency plan when other libraries were raised" do
    expect(described_class.select(**paths, change_count: 2)).to eq(
      "name" => "dependency", "prompt_path" => paths.fetch(:dependency_prompt_path)
    )
  end

  it "uses the standard plan when no in-scope dependency was raised" do
    expect(described_class.select(**paths)).to eq(
      "name" => "", "prompt_path" => paths.fetch(:prompt_path)
    )
  end

  it "requires the Playbook prompt for a Playbook raise" do
    expect {
      described_class.select(**paths.merge(playbook_prompt_path: ""), playbook_raised: true, change_count: 1)
    }.to raise_error(/Playbook prompt required/)
  end

  it "falls back to the standard plan when the optional dependency prompt is absent" do
    expect(described_class.select(**paths.merge(dependency_prompt_path: ""), change_count: 1))
      .to eq("name" => "", "prompt_path" => paths.fetch(:prompt_path))
  end
end
