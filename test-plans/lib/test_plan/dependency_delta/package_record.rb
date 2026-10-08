# frozen_string_literal: true

module TestPlan
  module DependencyDelta
    # `name` is the package the lockfile actually installed, which is what evidence has
    # to be fetched for. `alias` is the name the manifest asked for, which is what a
    # package.json dependency or a workspace member is listed under. For everything
    # except an npm alias the two are the same.
    PackageRecord = Struct.new(:name, :alias, :version, :resolved, :integrity, keyword_init: true) do
      def initialize(**attributes)
        super
        self.alias ||= name
      end
    end
  end
end
