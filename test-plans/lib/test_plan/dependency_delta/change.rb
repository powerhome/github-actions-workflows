require "uri"

require_relative "./git_locator"

module TestPlan
  module DependencyDelta
    Change = Struct.new(
      :ecosystem,
      :name,
      :old_version,
      :new_version,
      :source,
      :old_locator,
      :new_locator,
      :old_integrity,
      :new_integrity,
      :direct,
      :lockfiles,
      keyword_init: true
    ) do
      def key
        [ecosystem, name, old_version, new_version, source, *source_identity]
      end

      # The artifact is identity, not the registry URL: one raise recorded through
      # different remotes in different lockfiles stayed undeduplicated and downloaded
      # twice. A checksum settles it and mirrors share theirs, so proxied copies collapse;
      # without one the registry host is enough to keep a private package from collapsing
      # into a public one of the same name and version. For Git it is the repository,
      # normalized so equivalent spellings collapse.
      def source_identity
        if source == "git"
          return [
            GitLocator.repository(old_locator) || old_locator,
            GitLocator.repository(new_locator) || new_locator,
          ]
        end

        [
          artifact_identity(old_locator, old_integrity),
          artifact_identity(new_locator, new_integrity),
        ]
      end

      def artifact_identity(locator, integrity)
        return integrity unless integrity.to_s.empty?

        URI.parse(locator.to_s).host || locator.to_s
      rescue URI::InvalidURIError
        locator.to_s
      end

      def to_h
        {
          "ecosystem" => ecosystem,
          "name" => name,
          "old_version" => old_version,
          "new_version" => new_version,
          "source" => source,
          "old_locator" => old_locator,
          "new_locator" => new_locator,
          "direct" => direct,
          "lockfiles" => lockfiles.sort,
        }
      end
    end
  end
end
