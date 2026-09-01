module TestPlan
  # Which shape of plan to ask the provider for.
  #
  # The profile resolves from the label before any lockfile has been read, so it cannot
  # know whether this is a Playbook raise -- the pull request whose diff is entirely
  # lockfiles, whose plan is organised by changed kit rather than by feature area. The
  # dependency delta finds that out. This picks between what the profile declared and
  # what the delta found, and names the choice so the render step can follow it.
  module Variant
    PLAYBOOK = "playbook".freeze
    DEFAULT = "".freeze

    module_function

    # A profile that declares no Playbook prompt keeps its single one, so adding the
    # variant to one profile does not change the other.
    def select(prompt_path:, playbook_prompt_path: "", playbook_kits_changed: false)
      if playbook_kits_changed && !playbook_prompt_path.to_s.empty?
        return { "name" => PLAYBOOK, "prompt_path" => playbook_prompt_path.to_s }
      end

      { "name" => DEFAULT, "prompt_path" => prompt_path.to_s }
    end
  end
end
