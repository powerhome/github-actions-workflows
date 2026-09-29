module TestPlan
  # The profile resolves from the label before any lockfile is read, so only the
  # dependency delta knows what was raised. Named so the render step follows the same
  # choice the provider was given.
  module Variant
    PLAYBOOK = "playbook".freeze
    DEPENDENCY = "dependency".freeze
    DEFAULT = "".freeze

  module_function

    def select(prompt_path:, playbook_prompt_path: "", dependency_prompt_path: "",
               playbook_raised: false, change_count: 0)
      if playbook_raised
        raise "Playbook prompt required for a Playbook raise" if playbook_prompt_path.to_s.empty?

        return { "name" => PLAYBOOK, "prompt_path" => playbook_prompt_path.to_s }
      end

      if change_count.to_i.positive? && !dependency_prompt_path.to_s.empty?
        return { "name" => DEPENDENCY, "prompt_path" => dependency_prompt_path.to_s }
      end

      { "name" => DEFAULT, "prompt_path" => prompt_path.to_s }
    end
  end
end
