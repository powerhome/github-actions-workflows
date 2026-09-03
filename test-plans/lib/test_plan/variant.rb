module TestPlan
  # Which shape of plan to ask the provider for. The profile resolves from the label
  # before any lockfile is read, so only the dependency delta knows whether this is a
  # Playbook raise. The choice is named so the render step can follow it.
  module Variant
    PLAYBOOK = "playbook".freeze
    DEFAULT = "".freeze

    module_function

    #
    # Changed kits are not enough on their own. The Playbook plan is told there is no
    # application diff to read and is pointed at the kit evidence instead, so a pull
    # request that bumps Playbook *and* touches application code would have had those
    # changes silently left out. The standard plan reads pr.diff and the kit evidence
    # both, so it is the right shape for a mixed pull request.
    def select(prompt_path:, playbook_prompt_path: "", playbook_kits_changed: false,
               lockfile_only: false)
      if playbook_kits_changed && lockfile_only && !playbook_prompt_path.to_s.empty?
        return { "name" => PLAYBOOK, "prompt_path" => playbook_prompt_path.to_s }
      end

      { "name" => DEFAULT, "prompt_path" => prompt_path.to_s }
    end
  end
end
