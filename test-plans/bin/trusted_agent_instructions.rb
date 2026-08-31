#!/usr/bin/env ruby

require_relative "../lib/test_plan/trusted_agent_instructions"

begin
  result = TestPlan::TrustedAgentInstructions.new(
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
