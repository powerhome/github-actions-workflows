# frozen_string_literal: true

require "json"

require_relative "./package_record"

module TestPlan
  module DependencyDelta
    # Reads the `packages` map npm has written since lockfileVersion 2. Version 1 nests a
    # `dependencies` tree instead and npm 7 rewrites it on the next install, so it is
    # reported as unreadable rather than parsed a second way.
    class NpmLockParser
      INSTALL_PREFIX = "node_modules/"

      def initialize(content)
        @content = content.to_s
      end

      def records
        lockfile = JSON.parse(@content)
        lockfile = {} unless lockfile.is_a?(Hash)
        packages = lockfile["packages"]
        unless packages.is_a?(Hash)
          raise "package-lock.json lockfileVersion #{lockfile["lockfileVersion"].inspect} " \
                "has no packages map; only lockfileVersion 2 and 3 are supported"
        end

        packages.filter_map do |key, entry|
          # A key outside node_modules/ is the root or a workspace member, and a link is
          # the installed pointer to one -- local code, not a dependency to fetch.
          next unless key.include?(INSTALL_PREFIX) && entry.is_a?(Hash)
          next if entry["link"] == true || !entry["version"].is_a?(String)

          # The last segment, so a nested install of b under a reads as b. An npm alias
          # installs under the requested name and records the real one in `name`.
          requested = key.split(INSTALL_PREFIX).last
          PackageRecord.new(
            name: entry["name"].is_a?(String) ? entry["name"] : requested,
            alias: requested,
            version: entry["version"],
            resolved: entry["resolved"],
            integrity: entry["integrity"]
          )
        end
      end
    end
  end
end
