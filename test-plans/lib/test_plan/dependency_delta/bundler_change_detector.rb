require "bundler"
require "set"
require_relative "./change"

module TestPlan
  module DependencyDelta
    class BundlerChangeDetector
      def detect(path:, old_content:, new_content:, direct_names: Set.new)
        return [] unless old_content && new_content

        old_lock = Bundler::LockfileParser.new(old_content)
        new_lock = Bundler::LockfileParser.new(new_content)
        old_specs = external_specs(old_lock)
        new_specs = external_specs(new_lock)
        old_git_sources = git_sources(old_content)
        new_git_sources = git_sources(new_content)
        direct_names = direct_names | new_lock.dependencies.keys.to_set

        new_specs.filter_map do |name, new_spec|
          old_spec = old_specs[name]
          next unless old_spec

          build_change(
            path: path,
            name: name,
            old_spec: old_spec,
            new_spec: new_spec,
            old_git: old_git_sources[name],
            new_git: new_git_sources[name],
            direct: direct_names.include?(name)
          )
        end
      rescue Bundler::BundlerError, ArgumentError => e
        raise "Unable to parse #{path}: #{e.message}"
      end

    private

      def external_specs(lock)
        lock.specs.each_with_object({}) do |spec, specs|
          next if spec.source.is_a?(Bundler::Source::Path) && !spec.source.is_a?(Bundler::Source::Git)

          current = specs[spec.name]
          specs[spec.name] = spec if current.nil? || spec.version > current.version
        end
      end

      def build_change(path:, name:, old_spec:, new_spec:, old_git:, new_git:, direct:)
        # A dependency that moves between RubyGems and Git changed where its code comes
        # from, which matters more than most version bumps -- but the two sides are not
        # comparable artifacts, so there is nothing to diff. Reporting it keeps the
        # change visible instead of dropping it as though nothing happened.
        if old_git.nil? != new_git.nil?
          return mixed_source_change(path: path, name: name, old_spec: old_spec,
                                     new_spec: new_spec, old_git: old_git,
                                     new_git: new_git, direct: direct)
        end

        if new_git
          old_revision = old_git && old_git["revision"]
          new_revision = new_git["revision"]
          return if old_revision.to_s.empty? || new_revision.to_s.empty? || old_revision == new_revision

          return Change.new(
            ecosystem: "bundler",
            name: name,
            old_version: old_revision,
            new_version: new_revision,
            source: "git",
            old_locator: old_git["remote"],
            new_locator: new_git["remote"],
            direct: direct,
            lockfiles: [path]
          )
        end

        return unless new_spec.version > old_spec.version

        Change.new(
          ecosystem: "bundler",
          name: name,
          old_version: old_spec.version.to_s,
          new_version: new_spec.version.to_s,
          source: "rubygems",
          old_locator: rubygems_remote(old_spec.source),
          new_locator: rubygems_remote(new_spec.source),
          direct: direct,
          lockfiles: [path]
        )
      end

      def mixed_source_change(path:, name:, old_spec:, new_spec:, old_git:, new_git:, direct:)
        Change.new(
          ecosystem: "bundler",
          name: name,
          old_version: old_git ? old_git["revision"].to_s : old_spec.version.to_s,
          new_version: new_git ? new_git["revision"].to_s : new_spec.version.to_s,
          source: "mixed",
          old_locator: old_git ? old_git["remote"] : rubygems_remote(old_spec.source),
          new_locator: new_git ? new_git["remote"] : rubygems_remote(new_spec.source),
          direct: direct,
          lockfiles: [path]
        )
      end

      def source_options(source)
        source.respond_to?(:options) ? source.options.transform_keys(&:to_s) : {}
      end

      # A GEM section can list several remotes, and the lockfile does not say which one a
      # given spec came from. Naming the first would let an internal gem read as public
      # whenever rubygems.org happens to sort first, which is the confusion the
      # provenance check exists to prevent. Ambiguity is reported as no remote at all, so
      # retrieval refuses rather than guesses.
      def rubygems_remote(source)
        remotes = Array(source_options(source)["remotes"])
        remotes.length == 1 ? remotes.first.to_s : ""
      end

      def git_sources(content)
        content.scan(/^GIT\n(.*?)(?=^[A-Z][A-Z ]*\n|\z)/m).each_with_object({}) do |(block), sources|
          remote = block[/^  remote:\s*(.+)$/, 1]
          revision = block[/^  revision:\s*(.+)$/, 1]
          specs = block.split(/^  specs:\s*$\n/, 2).last.to_s
          specs.scan(/^    ([^\s(]+) \(/).flatten.each do |name|
            sources[name] = { "remote" => remote, "revision" => revision }
          end
        end
      end
    end
  end
end
