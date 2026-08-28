#!/usr/bin/env ruby

require_relative "test_plan_formatter"
require_relative "test_plan_parser"

begin
  json_path = ENV.fetch("TEST_PLAN_JSON_PATH")
  comment_path = ENV.fetch("TEST_PLAN_COMMENT_PATH")
  pull_request_title = ENV.fetch("PULL_REQUEST_TITLE", "")
  profile_name = ENV.fetch("TEST_PLAN_PROFILE_NAME", "Test Plan")
  generation_warning = ENV.fetch("TEST_PLAN_GENERATION_WARNING", "")

  parsed = TestPlanParser.parse_file(json_path)
  comment = TestPlanFormatter.new(
    parsed: parsed,
    pull_request_title: pull_request_title,
    profile_name: profile_name,
    generation_warning: generation_warning
  ).render

  File.write(comment_path, comment, encoding: Encoding::UTF_8)
  warn "[test_plan] Rendered #{comment_path}"
rescue JSON::ParserError => e
  warn "Failed to parse test-plan JSON: #{e.message}"
  exit 1
rescue Errno::ENOENT => e
  warn "Test-plan JSON not found: #{e.message}"
  exit 1
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end
