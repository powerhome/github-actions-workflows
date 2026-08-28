#!/usr/bin/env ruby

require "fileutils"
require "find"

# The checked-out pull-request head is untrusted input: anyone who can open a PR can
# add files to it. Agent CLIs load instructions from the workspace they run in
# (.cursor/rules, .cursorrules, AGENTS.md) and honour .cursorignore, so left in place a
# pull request could dictate its own test plan or hide the code it changed from the
# reviewer. The action's prompt is deliberately self-contained, so removing them costs
# no legitimate context.
class AgentInstructionQuarantine
  FILE_NAMES = %w[.cursorrules .cursorignore .cursorindexingignore AGENTS.md].freeze
  DIRECTORY_NAMES = %w[.cursor].freeze
  PRUNED_DIRECTORY_NAMES = %w[.git].freeze

  def initialize(root)
    @root = root
  end

  def run
    targets = find_targets
    FileUtils.rm_rf(targets)
    targets
  end

private

  def find_targets
    targets = []

    Find.find(@root) do |path|
      basename = File.basename(path)

      if File.directory?(path)
        if PRUNED_DIRECTORY_NAMES.include?(basename)
          Find.prune
        elsif DIRECTORY_NAMES.include?(basename)
          targets << path
          Find.prune
        end
      elsif FILE_NAMES.include?(basename)
        targets << path
      end
    end

    targets
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    root = ENV.fetch("GITHUB_WORKSPACE")
    removed = AgentInstructionQuarantine.new(root).run

    if removed.empty?
      warn "[test_plan] No agent-instruction paths found in the pull-request head"
    else
      warn "[test_plan] Removed agent-instruction paths from the pull-request head:"
      removed.each { |path| warn "  #{path.delete_prefix("#{root}/")}" }
    end
  rescue KeyError => e
    warn "Missing required environment variable: #{e.message}"
    exit 1
  rescue => e
    warn e.message
    exit 1
  end
end
