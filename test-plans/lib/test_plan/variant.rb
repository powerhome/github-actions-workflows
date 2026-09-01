module TestPlan
  # Which shape of plan to ask the provider for. The profile resolves from the label
  # before any lockfile is read, so only the dependency delta knows whether this is a
  # Playbook raise. The choice is named so the render step can follow it.
  module Variant
    PLAYBOOK = "playbook".freeze
    DEFAULT = "".freeze

    module_function

    def select(prompt_path:, playbook_prompt_path: "", playbook_kits_changed: false)
      if playbook_kits_changed && !playbook_prompt_path.to_s.empty?
        return { "name" => PLAYBOOK, "prompt_path" => playbook_prompt_path.to_s }
      end

      { "name" => DEFAULT, "prompt_path" => prompt_path.to_s }
    end
  end
end
