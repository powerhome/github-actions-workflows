require "json"
require "set"
require_relative "./bundler_change_detector"
require_relative "./yarn_change_detector"

module TestPlan
  module DependencyDelta
    class ChangeDetector
      LockfileProblem = Struct.new(:path, :message, keyword_init: true) do
        def to_h
          { "lockfile" => path, "warning" => message }
        end
      end

      # Anchored to the start of a line so a comment is not read as a declaration.
      # Unanchored, \bgem also matched prose: "Specify your gem's dependencies" opens a
      # quote, and the capture then ran to the next quote anywhere in the file, which
      # both invented a name and desynchronised the pairing for the rest of it, so a
      # real declaration further down could be missed as well.
      GEM = /^[ \t]*gem\s*\(?\s*["']([^"'\n]+)["']/
      # A gemspec names its receiver: spec.add_dependency, s.add_runtime_dependency.
      ADD_DEPENDENCY =
        /^[ \t]*(?:[A-Za-z_]\w*\.)?add_(?:runtime_)?dependency\s*\(?\s*["']([^"'\n]+)["']/

      attr_reader :problems

      def initialize(snapshot)
        @snapshot = snapshot
        @problems = []
      end

      def detect
        changed = @snapshot.changed_dependency_files
        direct_names, workspace_names = package_names
        ruby_direct_names = ruby_dependency_names
        changes = []

        changed.grep(%r{(?:\A|/)Gemfile\.lock\z}).each do |path|
          changes.concat(
            detecting(path) do
              BundlerChangeDetector.new.detect(
                path: path,
                old_content: @snapshot.read(@snapshot.merge_base_sha, path),
                new_content: @snapshot.read(@snapshot.head_sha, path),
                direct_names: ruby_direct_names
              )
            end
          )
        end

        changed.grep(%r{(?:\A|/)yarn\.lock\z}).each do |path|
          changes.concat(
            detecting(path) do
              YarnChangeDetector.new.detect(
                path: path,
                old_content: @snapshot.read(@snapshot.merge_base_sha, path),
                new_content: @snapshot.read(@snapshot.head_sha, path),
                direct_names: direct_names,
                workspace_names: workspace_names
              )
            end
          )
        end

        deduplicate(changes)
      end

    private

      # An unreadable lockfile costs us evidence for that file only. Recording it as a
      # warning keeps the rest of the delta, and the test plan itself, intact.
      def detecting(path)
        yield
      rescue => e
        @problems << LockfileProblem.new(path: path, message: e.message)
        []
      end

      def package_names
        direct = Set.new
        local = Set.new
        packages = []

        @snapshot.paths_at(@snapshot.head_sha, "package.json").each do |path|
          content = @snapshot.read(@snapshot.head_sha, path)
          next unless content

          package = JSON.parse(content)
          packages << [path, package] if package.is_a?(Hash)
        rescue JSON::ParserError
          next
        end

        workspace_globs = packages.flat_map { |path, package| workspace_globs(path, package) }
        packages.each do |path, package|
          if package["name"] && (path.start_with?("components/") || workspace_path?(path, workspace_globs))
            local << package["name"]
          end

          %w[dependencies devDependencies optionalDependencies peerDependencies].each do |field|
            requirements = package[field]
            next unless requirements.is_a?(Hash)

            requirements.each do |name, requirement|
              direct << name
              local << name if local_requirement?(requirement)
            end
          end
        end

        [direct, local]
      end

      # A workspace glob is relative to the package.json that declares it, not to the
      # repository root. Flattening every glob into one root-relative list meant a
      # nested package declaring "packages/*" never matched its own members, and their
      # upgrades were reported as external dependencies.
      def workspace_globs(package_json_path, package)
        directory = File.dirname(package_json_path)

        patterns(package).map do |pattern|
          directory == "." ? pattern.to_s : File.join(directory, pattern.to_s)
        end
      end

      def patterns(package)
        workspaces = package["workspaces"]
        case workspaces
        when Array
          workspaces
        when Hash
          Array(workspaces["packages"])
        else
          []
        end
      end

      def workspace_path?(package_json_path, globs)
        package_directory = File.dirname(package_json_path)
        globs.any? do |glob|
          File.fnmatch?(glob, package_directory, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        end
      end

      def local_requirement?(requirement)
        requirement.to_s.match?(%r{\A(?:file|link|workspace):})
      end

      def ruby_dependency_names
        paths = @snapshot.paths_at(@snapshot.head_sha, "Gemfile") +
          @snapshot.paths_at(@snapshot.head_sha, ".gemspec")

        paths.each_with_object(Set.new) do |path, names|
          content = @snapshot.read(@snapshot.head_sha, path).to_s
          [GEM, ADD_DEPENDENCY].each do |pattern|
            content.scan(pattern).flatten.each { |name| names << name }
          end
        end
      end

      def deduplicate(changes)
        changes.each_with_object({}) do |change, unique|
          if (existing = unique[change.key])
            existing.direct ||= change.direct
            existing.lockfiles |= change.lockfiles
          else
            unique[change.key] = change
          end
        end.values
      end
    end
  end
end
