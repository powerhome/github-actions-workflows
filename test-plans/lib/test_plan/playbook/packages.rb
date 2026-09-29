# frozen_string_literal: true

module TestPlan
  module Playbook
    # One upstream release published as a gem and a package. Named once because the delta
    # decides scope and plan shape by this list and the formatter decides which manifest
    # entry is the Playbook raise by it: a third name reaching one and not the other would
    # leave a raise in scope with nowhere in the plan to appear.
    PACKAGE_NAMES = %w[playbook_ui playbook-ui].freeze
  end
end
