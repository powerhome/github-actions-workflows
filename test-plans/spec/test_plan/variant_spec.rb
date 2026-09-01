require_relative "../spec_helper"
require "test_plan/variant"

RSpec.describe TestPlan::Variant do
  it "asks for the Playbook shape when the delta found changed kits" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "/action/prompts/cobra_playbook_test_plan.md",
      playbook_kits_changed: true
    )

    expect(selection).to eq(
      "name" => "playbook", "prompt_path" => "/action/prompts/cobra_playbook_test_plan.md"
    )
  end

  it "keeps the profile's prompt when no kit changed" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "/action/prompts/cobra_playbook_test_plan.md",
      playbook_kits_changed: false
    )

    expect(selection).to eq("name" => "", "prompt_path" => "/action/prompts/cobra_test_plan.md")
  end

  # Adding the variant to one profile must not change how another one runs, and a run
  # whose profile declares no Playbook prompt has nothing to switch to.
  it "keeps the profile's prompt when the profile declares no Playbook variant" do
    selection = described_class.select(
      prompt_path: "/action/prompts/cobra_test_plan.md",
      playbook_prompt_path: "",
      playbook_kits_changed: true
    )

    expect(selection).to eq("name" => "", "prompt_path" => "/action/prompts/cobra_test_plan.md")
  end
end
