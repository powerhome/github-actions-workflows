require_relative "../spec_helper"
require "test_plan/variant"

RSpec.describe TestPlan::Variant do
  it "asks for the Playbook shape when the delta found changed kits" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "/action/prompts/cobra_playbook_test_plan.md",
      playbook_kits_changed: true,
      lockfile_only: true
    )

    expect(selection).to eq(
      "name" => "playbook", "prompt_path" => "/action/prompts/cobra_playbook_test_plan.md"
    )
  end

  it "keeps the profile's prompt when no kit changed" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "/action/prompts/cobra_playbook_test_plan.md",
      playbook_kits_changed: false,
      lockfile_only: true
    )

    expect(selection).to eq("name" => "", "prompt_path" => "/action/prompts/cobra_test_plan.md")
  end

  # The Playbook plan is told there is no application diff to read, so a pull request that
  # bumps Playbook and also touches application code would have had those changes silently
  # left out of the plan. The standard plan reads pr.diff and the kit evidence both.
  it "keeps the profile's prompt when the pull request changed more than declarations" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "/action/prompts/cobra_playbook_test_plan.md",
      playbook_kits_changed: true,
      lockfile_only: false
    )

    expect(selection).to eq("name" => "", "prompt_path" => "/action/prompts/cobra_test_plan.md")
  end

  # Adding the variant to one profile must not change how another one runs.
  it "keeps the profile's prompt when the profile declares no Playbook variant" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "",
      playbook_kits_changed: true,
      lockfile_only: true
    )

    expect(selection).to eq("name" => "", "prompt_path" => "/action/prompts/cobra_test_plan.md")
  end
end
