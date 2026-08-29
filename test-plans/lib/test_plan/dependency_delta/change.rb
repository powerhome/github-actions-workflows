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

      # Registry URLs are mirror detail, not identity: the same raise recorded through
      # different remotes in different component lockfiles is still one raise, and keying on
      # the raw URLs left it undeduplicated and downloaded twice. For Git the repository is
      # identity, so keep it -- normalized, so equivalent spellings still collapse.
      def source_identity
        return [] unless source == "git"

        [
          GitLocator.repository(old_locator) || old_locator,
          GitLocator.repository(new_locator) || new_locator,
        ]
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
