#!/usr/bin/env ruby

require "fileutils"
require "find"
require "open3"

# Agent CLIs load instructions from the workspace they run in (.cursor/rules,
# .cursorrules, AGENTS.md) and honour .cursorignore. The workspace here is the
# pull-request head, which anyone who can open a pull request controls -- but the
# repositories this runs against keep real agent harness that the provider benefits
# from, so deleting it outright would cost legitimate context.
#
# Instead, reset those paths to the merge base. Instructions that made it through
# review still apply; anything the pull request added or edited does not.
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

if $PROGRAM_NAME == __FILE__
  begin
    result = TrustedAgentInstructions.new(
      root: ENV.fetch("GITHUB_WORKSPACE"),
      base_sha: ENV.fetch("BASE_SHA"),
      head_sha: ENV.fetch("HEAD_SHA")
    ).run

    result.restored.each { |path| warn "[test_plan] Reset to merge base: #{path}" }
    result.removed.each { |path| warn "[test_plan] Removed (added by this PR): #{path}" }
    if result.restored.empty? && result.removed.empty?
      warn "[test_plan] Agent instructions already match the merge base"
    end
  rescue KeyError => e
    warn "Missing required environment variable: #{e.message}"
    exit 1
  rescue => e
    warn e.message
    exit 1
  end
end
