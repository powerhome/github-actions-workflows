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
      # The reserved name itself counts: a pull request can commit a regular file called
      # .cursor, which survives a reset that only looks inside such a directory and then
      # makes the provider fail at `mkdir -p .cursor` instead of producing a plan.
      return true if DIRECTORY_NAMES.include?(segments.last)

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
          next if unchanged?(absolute, trusted)

          write_trusted(absolute, trusted)
          restored << relative
        else
          next unless File.exist?(absolute) || File.symlink?(absolute)

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
          relative = path.delete_prefix("#{@root}#{File::SEPARATOR}")

          # Checked before the directory branch, which follows links: a .cursor symlink
          # reads as a directory and would be skipped, while Find refuses to descend it,
          # so nothing beneath it is ever seen either. Cursor has no such reluctance --
          # it follows the link and reads whatever the pull request put there.
          if File.symlink?(path)
            paths << relative if self.class.instruction_path?(relative) ||
              DIRECTORY_NAMES.include?(File.basename(path))
            next
          end

          if File.directory?(path)
            Find.prune if PRUNED_DIRECTORY_NAMES.include?(File.basename(path))
            next
          end

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

    # Compared without following links: a symlink standing where a file belongs is a
    # change the pull request made, whatever it happens to point at.
    def unchanged?(absolute, trusted)
      return false if symlinked_component?(absolute)

      File.file?(absolute) && File.binread(absolute) == trusted
    end

    # A pull request can put something other than the expected file at any point along
    # the path: a symlink, whose target the write would land in rather than the
    # workspace; a directory where the file belongs, which File.binwrite cannot write
    # to; or a regular file where a parent directory belongs, which mkdir_p cannot
    # descend. The last two raise and fail the whole run before a plan is generated.
    #
    # Whatever stands in the way is removed first, which is the answer this class gives
    # everywhere else: what the pull request put there is not what the merge base holds.
    # FileUtils.rm_rf unlinks a symlink rather than following it.
    def write_trusted(absolute, trusted)
      components = each_component(absolute).to_a

      components[0..-2].each do |path|
        FileUtils.rm_rf(path) if File.symlink?(path) || (File.exist?(path) && !File.directory?(path))
      end

      leaf = components.last
      FileUtils.rm_rf(leaf) if File.symlink?(leaf) || (File.exist?(leaf) && !File.file?(leaf))

      FileUtils.mkdir_p(File.dirname(absolute))
      File.binwrite(absolute, trusted)
    end

    def symlinked_component?(absolute)
      each_component(absolute).any? { |path| File.symlink?(path) }
    end

    def each_component(absolute)
      return enum_for(:each_component, absolute) unless block_given?

      current = @root
      absolute.delete_prefix("#{@root}#{File::SEPARATOR}").split(File::SEPARATOR).each do |segment|
        current = File.join(current, segment)
        yield current
      end
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
