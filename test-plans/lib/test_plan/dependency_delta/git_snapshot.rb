require "open3"

require_relative "../command_output"

module TestPlan
  module DependencyDelta
    class GitSnapshot
      DEPENDENCY_FILENAMES = %w[Gemfile.lock yarn.lock package.json].freeze
      # Generated files: their content is resolver output, never application behaviour.
      LOCKFILE_NAMES = %w[Gemfile.lock yarn.lock].freeze
      # Hand-written, so the name alone proves nothing. A version bump edits these -- this
      # repository pins Playbook exactly, so a bump has to touch several package.json files
      # and a gemspec -- but so does adding an npm script or a Bundler require: false, and
      # those do change behaviour. The content decides, not the filename.
      DECLARATION_NAMES = %w[Gemfile package.json .gemspec].freeze
      # A quoted literal that starts with a digit, optionally behind a range operator.
      # "17.2.0-rc.1" and "^1.2.3" are versions; "rack" and "build" are not, which is what
      # keeps a changed dependency name or script from normalising away.
      VERSION_LITERAL = /(["'])[~^>=<[:space:]]*\d[\w.+\-]*\1/.freeze

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

      # Whether this pull request raised dependency versions and did nothing else -- the
      # premise the Playbook plan is written on, since it is told there is no application
      # diff to read and is pointed at the kit evidence instead.
      #
      # False for an empty diff as well as a mixed one: "nothing changed" is not the claim
      # that licenses a plan which never looks at the application. Every uncertain case
      # answers false, because the cost is only the standard plan, which reads pr.diff and
      # the kit evidence both.
      def declarations_only?
        changed = changed_files
        return false if changed.empty?

        changed.all? { |path| lockfile?(path) || version_only_declaration?(path) }
      end

      # Identical once version literals are blanked, so the only thing that moved was a
      # version. An added npm script, a changed group, a require: false, a renamed
      # dependency -- none of those normalise to what was there before.
      def version_only_declaration?(path)
        return false unless DECLARATION_NAMES.any? { |name| self.class.matches?(path, name) }

        old_content = read(merge_base_sha, path)
        new_content = read(head_sha, path)
        # An added or deleted declaration file is a change in its own right.
        return false if old_content.nil? || new_content.nil?

        blank_versions(old_content) == blank_versions(new_content)
      end

      def blank_versions(content)
        content.gsub(VERSION_LITERAL, "\"<version>\"")
      end

      def lockfile?(path)
        LOCKFILE_NAMES.any? { |name| self.class.matches?(path, name) }
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
