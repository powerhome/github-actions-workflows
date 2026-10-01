# frozen_string_literal: true

require "rubygems"

require_relative "../playbook/packages"
require_relative "./public_downloader"
require_relative "./version_spelling"

module TestPlan
  module DependencyDelta
    # An alpha is versioned from the release its branch started on, so it can sort below
    # the release candidate a project has since installed. Read against that candidate,
    # everything the candidate added reads as removed by the alpha, and the plan asks for
    # testing of work the alpha never touched. The release the alpha was built from
    # differs from the alpha by what the alpha itself changed.
    class PlaybookAlphaBaseline
      REGISTRY_SOURCES = %w[rubygems npm].freeze

      def initialize(downloader: PublicDownloader.new)
        @downloader = downloader
      end

      # The change read against the alpha's base release, or unchanged when it is not a
      # Playbook alpha below what is installed, or when that release is not published.
      def resolve(change)
        base = base_release(change)
        return change unless base

        rebase(change, base)
      rescue => e
        warn "[test_plan] Alpha baseline skipped for #{change.name}: #{e.message}"
        change
      end

    private

      def base_release(change)
        return unless Playbook::PACKAGE_NAMES.include?(change.name)
        return unless REGISTRY_SOURCES.include?(change.source)

        old_version = version(change.old_version)
        new_version = version(change.new_version)
        return unless old_version && new_version
        return unless alpha?(new_version) && new_version < old_version

        base = new_version.release
        base.to_s unless base == old_version
      end

      def rebase(change, base)
        rebased = change.dup
        rebased.installed_version = change.old_version
        rebased.old_version = base

        case change.source
        when "npm"
          # Proven public by the registry, which the installed copy's locator may not be.
          dist = @downloader.npm_dist(change.name, base)
          rebased.old_locator = dist.fetch("tarball")
          rebased.old_integrity = dist["integrity"]
        else
          @downloader.rubygems_version(change.name, base)
        end

        rebased
      end

      def version(text)
        canonical = VersionSpelling.canonical(text)
        Gem::Version.new(canonical) if Gem::Version.correct?(canonical)
      end

      # Gem::Version spells a prerelease "pre" then its tag, or the tag alone.
      def alpha?(version)
        tag = version.segments.drop_while { |segment| segment.is_a?(Integer) }
                     .reject { |segment| segment == "pre" }.first
        tag.to_s.casecmp?("alpha")
      end
    end
  end
end
