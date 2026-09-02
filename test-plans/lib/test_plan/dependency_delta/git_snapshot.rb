require "open3"

require_relative "../command_output"

module TestPlan
  module DependencyDelta
    class GitSnapshot
      DEPENDENCY_FILENAMES = %w[Gemfile.lock yarn.lock package.json].freeze
      # What a version bump edits, lockfiles plus the declarations above them. A pull
      # request that changed only these changed no application behaviour, which is the
      # premise the Playbook plan is written on: it is told there is no application diff
      # to read, so it must not be chosen for a pull request that has one.
      DECLARATION_FILENAMES = (DEPENDENCY_FILENAMES + %w[Gemfile .gemspec]).freeze

      # A trailing-substring test also accepts "my-package.json" or "custom-Gemfile", which
      # are unrelated files. Names have to match a whole path segment; ".gemspec" stays an
      # extension match.
      def self.matches?(path, name)
        name.start_with?(".") ? File.extname(path) == name : File.basename(path) == name
      end

      def initialize(workspace:, base_sha:, head_sha:)
        @workspace = workspace
        @base_sha = base_sha
        @head_sha = head_sha
      end

      attr_reader :base_sha, :head_sha

      # pr.diff is a merge-base diff, so dependency evidence has to compare against the
      # merge base too. Reading the base tip instead would attribute changes made on the
      # base branch after the PR forked to the PR itself.
      def merge_base_sha
        @merge_base_sha ||= git("merge-base", base_sha, head_sha).strip
      end

      def changed_files
        git("diff", "--name-only", "#{merge_base_sha}..#{head_sha}")
          .lines.map(&:strip).reject(&:empty?)
      end

      def changed_dependency_files
        changed_files.select do |path|
          DEPENDENCY_FILENAMES.any? { |name| self.class.matches?(path, name) }
        end
      end

      # False for an empty diff as well as a mixed one: "nothing changed" is not the same
      # claim as "only declarations changed", and only the second one licenses a plan that
      # never looks at the application.
      def declarations_only?
        changed = changed_files
        return false if changed.empty?

        changed.all? do |path|
          DECLARATION_FILENAMES.any? { |name| self.class.matches?(path, name) }
        end
      end

      def paths_at(ref, name)
        git("ls-tree", "-r", "--name-only", ref).lines.map(&:strip).select do |path|
          self.class.matches?(path, name)
        end
      end

      def read(ref, path)
        git("show", "#{ref}:#{path}")
      rescue RuntimeError
        nil
      end

    private

      def git(*args)
        stdout, stderr, status = Open3.capture3("git", *args, chdir: @workspace)
        unless status.success?
          raise "git #{args.join(" ")} failed: #{CommandOutput.utf8(stderr).strip}"
        end

        CommandOutput.utf8(stdout)
      end
    end
  end
end
