require "rubygems"

module TestPlan
  module DependencyDelta
    # RubyGems and npm spell one prerelease two ways -- the playbook_ui gem publishes
    # 17.2.0.pre.rc.0 for the release npm publishes as 17.2.0-rc.0, tagged v17.2.0-rc.0.
    # Comparing and rendering stay separate calls because they need different answers.
    module VersionSpelling
      # Same release? Gem::Version rewrites a hyphen to ".pre." on the way in, so both
      # spellings already share a canonical form. A Git revision will not parse, and
      # compares as written.
      def self.canonical(version)
        text = version.to_s
        return text unless Gem::Version.correct?(text)

        Gem::Version.new(text).to_s
      end

      # How might this release be spelled in a Git tag, or in changelog prose? Outside
      # RubyGems the ".pre." separator is a hyphen. The trailing dot is required: a bare
      # 17.2.0.pre names no prerelease to hyphenate.
      def self.spellings(version)
        text = version.to_s
        [text, text.sub(/\.pre\./, "-")].uniq.reject(&:empty?)
      end
    end
  end
end
