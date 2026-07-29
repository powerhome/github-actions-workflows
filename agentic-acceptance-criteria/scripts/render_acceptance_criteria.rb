#!/usr/bin/env ruby

require_relative "acceptance_criteria_formatter"
require_relative "acceptance_criteria_parser"

begin
  json_path = ENV.fetch("ACCEPTANCE_CRITERIA_JSON_PATH")
  comment_path = ENV.fetch("ACCEPTANCE_CRITERIA_COMMENT_PATH")
  pull_request_title = ENV.fetch("PULL_REQUEST_TITLE", "")

  parsed = AcceptanceCriteriaParser.parse_file(json_path)
  comment = AcceptanceCriteriaFormatter.new(
    parsed: parsed,
    pull_request_title: pull_request_title
  ).render

  File.write(comment_path, comment)
  warn "[acceptance_criteria] Rendered #{comment_path}"
rescue JSON::ParserError => e
  warn "Failed to parse acceptance-criteria JSON: #{e.message}"
  exit 1
rescue Errno::ENOENT => e
  warn "Acceptance-criteria JSON not found: #{e.message}"
  exit 1
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end
