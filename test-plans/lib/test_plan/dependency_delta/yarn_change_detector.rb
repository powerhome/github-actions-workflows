require_relative "./change"
require_relative "./yarn_lock_parser"

module TestPlan
  module DependencyDelta
    class YarnChangeDetector
      def detect(path:, old_content:, new_content:, direct_names:, workspace_names:)
        return [] unless old_content && new_content

        old_by_name = YarnLockParser.new(old_content).records.group_by(&:name)
        new_by_name = YarnLockParser.new(new_content).records.group_by(&:name)

        new_by_name.flat_map do |name, new_records|
          # Grouped by the installed package, since that is the artifact whose evidence
          # is fetched. A manifest lists the name it asked for, so workspace membership
          # and direct-dependency status are decided by the alias.
          aliases = new_records.map(&:alias)
          next [] if aliases.any? { |requested| workspace_names.include?(requested) }

          old_records = old_by_name.fetch(name, [])
          direct = aliases.any? { |requested| direct_names.include?(requested) }
          version_changes(path, name, old_records, new_records, direct) +
            git_changes(path, name, old_records, new_records, direct) +
            mixed_source_changes(path, name, old_records, new_records, direct)
        end
      end

    private

      def version_changes(path, name, old_records, new_records, direct)
        old_versions = old_records.map(&:version).uniq
        new_versions = new_records.map(&:version).uniq
        removed = old_versions - new_versions
        added = new_versions - old_versions

        added.filter_map do |new_version|
          old_version = removed.select { |candidate| version(candidate) < version(new_version) }.max_by { |candidate| version(candidate) }
          next unless old_version

          old_record = old_records.find { |record| record.version == old_version }
          new_record = new_records.find { |record| record.version == new_version }
          next if git_locator?(old_record&.resolved) || git_locator?(new_record&.resolved)

          Change.new(
            ecosystem: "yarn",
            name: name,
            old_version: old_version,
            new_version: new_version,
            source: "npm",
            old_locator: old_record&.resolved,
            new_locator: new_record&.resolved,
            old_integrity: old_record&.integrity,
            new_integrity: new_record&.integrity,
            direct: direct,
            lockfiles: [path]
          )
        rescue ArgumentError
          nil
        end
      end

      def git_changes(path, name, old_records, new_records, direct)
        old_git = old_records.select { |record| git_locator?(record.resolved) }
        new_git = new_records.select { |record| git_locator?(record.resolved) }

        pair_git_records(old_git, new_git).filter_map do |old_record, new_record|
          next if old_record.resolved == new_record.resolved

          Change.new(
            ecosystem: "yarn",
            name: name,
            old_version: git_revision(old_record.resolved),
            new_version: git_revision(new_record.resolved),
            source: "git",
            old_locator: old_record.resolved,
            new_locator: new_record.resolved,
            direct: direct,
            lockfiles: [path]
          )
        end
      end

      # A Git dependency can move revision with or without changing its declared version,
      # and version_changes deliberately ignores Git records. Match same-version records
      # first, then pair whatever is left in version order so a simultaneous version and
      # revision bump is still reported instead of dropped.
      def pair_git_records(old_git, new_git)
        remaining_old = old_git.dup
        pairs = []
        unmatched_new = []

        new_git.each do |new_record|
          index = remaining_old.index { |candidate| candidate.version == new_record.version }
          if index
            pairs << [remaining_old.delete_at(index), new_record]
          else
            unmatched_new << new_record
          end
        end

        leftover_old = remaining_old.sort_by { |record| record.version.to_s }
        unmatched_new.sort_by { |record| record.version.to_s }.each_with_index do |new_record, index|
          old_record = leftover_old[index]
          pairs << [old_record, new_record] if old_record
        end

        pairs
      end

      # version_changes skips any pair with a Git side and git_changes pairs only Git
      # with Git, so a dependency moving between a Git locator and npm fell through
      # both and produced no evidence and no warning. The two sides are not comparable
      # artifacts, so this reports the transition rather than trying to diff it.
      def mixed_source_changes(path, name, old_records, new_records, direct)
        return [] if old_records.empty? || new_records.empty?

        # One name can legitimately carry both npm and Git selectors at once. Asking
        # whether any record is Git called that a transition, and reported one on top of
        # the real raise that version_changes had already found. A transition is only
        # readable when each side is entirely one kind.
        return [] unless uniform?(old_records) && uniform?(new_records)

        old_git = git_locator?(old_records.first.resolved)
        new_git = git_locator?(new_records.first.resolved)
        return [] if old_git == new_git

        old_record = old_records.last
        new_record = new_records.last
        [
          Change.new(
            ecosystem: "yarn",
            name: name,
            old_version: old_git ? git_revision(old_record.resolved) : old_record.version,
            new_version: new_git ? git_revision(new_record.resolved) : new_record.version,
            source: "mixed",
            old_locator: old_record.resolved,
            new_locator: new_record.resolved,
            direct: direct,
            lockfiles: [path]
          ),
        ]
      end

      def uniform?(records)
        records.map { |record| git_locator?(record.resolved) }.uniq.length == 1
      end

      def version(value)
        normalized = value.to_s.sub(/\Av/, "").split("+", 2).first
        Gem::Version.new(normalized)
      end

      def git_locator?(value)
        value.to_s.match?(%r{(?:github\.com|git\+|\.git#)})
      end

      def git_revision(value)
        locator = value.to_s
        return locator.split("#", 2).last if locator.include?("#")

        # yarn v1 resolves `github:owner/repo#ref` to a codeload tarball URL whose last
        # path segment is the revision, with no fragment to split on.
        match = locator.match(%r{codeload\.github\.com/[^/]+/[^/]+/(?:tar\.gz|zip)/(.+)\z})
        match ? match[1] : locator
      end
    end
  end
end
