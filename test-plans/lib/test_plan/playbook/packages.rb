# frozen_string_literal: true

module TestPlan
  module Playbook
    # One upstream release published as a gem and a package. Named once because the delta
    # decides scope and plan shape by this list and the formatter decides which manifest
    # entry is the Playbook raise by it: a third name reaching one and not the other would
    # leave a raise in scope with nowhere in the plan to appear.
    PACKAGE_NAMES = %w[playbook_ui playbook-ui].freeze

    # An alpha is versioned from the release its branch started on, while master keeps
    # moving through RCs, so it can sort below the RC already installed.
    ALPHA_BUILD = /\A\d+\.\d+\.\d+(?:\.pre\.|-)alpha\./

    def self.alpha_build?(name, version)
      PACKAGE_NAMES.include?(name) && version.to_s.match?(ALPHA_BUILD)
    end
  end
end
