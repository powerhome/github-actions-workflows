module TestPlan
  module Playbook
    # The gem and the npm package published together as one upstream release. Named
    # rather than inferred, and named once: the delta decides scope and plan shape by
    # this list, and the formatter decides which manifest entry is the Playbook raise by
    # it, so a third published name reaching one and not the other would leave a raise
    # in scope with nowhere in the plan to appear.
    PACKAGE_NAMES = %w[playbook_ui playbook-ui].freeze
  end
end
