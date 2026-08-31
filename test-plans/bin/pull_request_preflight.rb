#!/usr/bin/env ruby

require_relative "../lib/test_plan/pull_request/preflight"

def normalize_line(value)
  value.to_s.gsub(/[\r\n]+/, " ").strip
end

begin
  client = TestPlan::PullRequest::Client.new(
    repository: ENV.fetch("GITHUB_REPOSITORY"),
    pull_request_number: ENV.fetch("PR_NUMBER")
  )
  result = TestPlan::PullRequest::Preflight.new(client: client).run

  File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
    output.puts("base_sha=#{result.fetch("baseRefOid")}")
    output.puts("head_sha=#{result.fetch("headRefOid")}")
    output.puts("title=#{normalize_line(result.fetch("title"))}")
    output.puts("mergeable=#{result.fetch("mergeable")}")
    output.puts("generate=#{result.fetch("generate")}")
    output.puts("blocked=#{result.fetch("blocked")}")
    output.puts("blocked_reason=#{result.fetch("blocked_reason")}")
  end
rescue JSON::ParserError => e
  warn "GitHub pull-request response was not valid JSON: #{e.message}"
  exit 1
rescue KeyError => e
  warn "Missing required value: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end
