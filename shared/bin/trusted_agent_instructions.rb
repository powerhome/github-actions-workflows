#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/trusted_agent_instructions"

begin
  result = TrustedAgentInstructions.new(
    root: ENV.fetch("GITHUB_WORKSPACE"),
    base_sha: ENV.fetch("BASE_SHA"),
    head_sha: ENV.fetch("HEAD_SHA")
  ).run

  result.restored.each { |path| warn "[agent] Reset to merge base: #{path}" }
  result.removed.each { |path| warn "[agent] Removed (added by this PR): #{path}" }
  if result.restored.empty? && result.removed.empty?
    warn "[agent] Agent instructions already match the merge base"
  end
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end
