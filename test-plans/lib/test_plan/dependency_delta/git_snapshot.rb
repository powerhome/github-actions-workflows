require "open3"

module TestPlan
  module DependencyDelta
    class GitSnapshot
      DEPENDENCY_FILENAMES = %w[Gemfile.lock yarn.lock package.json].freeze

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

      def changed_dependency_files
        stdout = git("diff", "--name-only", "#{merge_base_sha}..#{head_sha}")
        stdout.lines.map(&:strip).select do |path|
          DEPENDENCY_FILENAMES.any? { |name| self.class.matches?(path, name) }
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
        raise "git #{args.join(" ")} failed: #{stderr.strip}" unless status.success?

        stdout
      end
    end
  end
end
