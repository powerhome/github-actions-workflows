require "fileutils"
require "find"
require "open3"

module TestPlan
  class TrustedAgentInstructions
    FILE_NAMES = %w[.cursorrules .cursorignore .cursorindexingignore AGENTS.md].freeze
    DIRECTORY_NAMES = %w[.cursor].freeze
    PRUNED_DIRECTORY_NAMES = %w[.git].freeze

    Result = Struct.new(:restored, :removed, keyword_init: true)

    def self.instruction_path?(relative)
      segments = relative.split("/")
      return true if segments[0..-2].any? { |segment| DIRECTORY_NAMES.include?(segment) }

      FILE_NAMES.include?(segments.last)
    end

    def initialize(root:, base_sha:, head_sha:)
      @root = root
      @base_sha = base_sha
      @head_sha = head_sha
    end

    def run
      restored = []
      removed = []

      (head_paths | base_paths).sort.each do |relative|
        absolute = File.join(@root, relative)

        if base_paths.include?(relative)
          trusted = read_base(relative)
          next if File.file?(absolute) && File.binread(absolute) == trusted

          FileUtils.mkdir_p(File.dirname(absolute))
          File.binwrite(absolute, trusted)
          restored << relative
        else
          next unless File.exist?(absolute)

          FileUtils.rm_rf(absolute)
          prune_empty_parents(absolute)
          removed << relative
        end
      end

      Result.new(restored: restored, removed: removed)
    end

    def merge_base_sha
      @merge_base_sha ||= git("merge-base", @base_sha, @head_sha).strip
    end

  private

    def head_paths
      @head_paths ||= [].tap do |paths|
        Find.find(@root) do |path|
          if File.directory?(path)
            Find.prune if PRUNED_DIRECTORY_NAMES.include?(File.basename(path))
            next
          end

          relative = path.delete_prefix("#{@root}#{File::SEPARATOR}")
          paths << relative if self.class.instruction_path?(relative)
        end
      end
    end

    def base_paths
      @base_paths ||= git("ls-tree", "-r", "--name-only", merge_base_sha)
        .lines.map(&:chomp).select { |path| self.class.instruction_path?(path) }
    end

    def read_base(relative)
      git("show", "#{merge_base_sha}:#{relative}")
    end

    # A path the pull request added may have brought empty directories with it.
    def prune_empty_parents(absolute)
      directory = File.dirname(absolute)

      while directory.start_with?("#{@root}#{File::SEPARATOR}") && Dir.exist?(directory) && Dir.empty?(directory)
        Dir.rmdir(directory)
        directory = File.dirname(directory)
      end
    end

    def git(*args)
      stdout, stderr, status = Open3.capture3("git", *args, chdir: @root, binmode: true)
      raise "git #{args.join(" ")} failed: #{stderr.strip}" unless status.success?

      stdout
    end
  end
end
