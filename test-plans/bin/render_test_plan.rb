#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/test_plan/response/standard_parser"
require_relative "../lib/test_plan/response/dependency_parser"
require_relative "../lib/test_plan/output/standard_formatter"
require_relative "../lib/test_plan/output/dependency_formatter"
require_relative "../lib/test_plan/output/playbook_formatter"
require_relative "../lib/test_plan/playbook/kit_facts"
require_relative "../lib/test_plan/response/playbook_parser"
require_relative "../lib/test_plan/profile"

begin
  json_path = ENV.fetch("TEST_PLAN_JSON_PATH")
  comment_path = ENV.fetch("TEST_PLAN_COMMENT_PATH")
  pull_request_title = ENV.fetch("PULL_REQUEST_TITLE", "")
  profile_name = ENV.fetch("TEST_PLAN_PROFILE_NAME", "Test Plan")
  generation_warning = ENV.fetch("TEST_PLAN_GENERATION_WARNING", "")

  # The choice the provider step was given, so the plan is rendered in the shape it was
  # asked for rather than whichever one the response resembles.
  variant = ENV["TEST_PLAN_VARIANT"].to_s
  kit_facts_path = ENV.fetch("PLAYBOOK_KIT_FACTS_PATH")
  manifest_path = ENV.fetch("DEPENDENCY_DELTA_MANIFEST_PATH")
  # Lazy: the standard plan renders from the response alone and should not fail over a
  # file it never reads.
  read_manifest = -> { JSON.parse(File.read(manifest_path, encoding: Encoding::UTF_8)) }

  options = {
    pull_request_title:,
    profile_name:,
    generation_warning:,
  }

  if variant == TestPlan::Profile::PLAYBOOK_PLAN
    parsed = TestPlan::Response::PlaybookParser.parse_file(json_path)
    # Coverage wording comes from what the action counted. load_file never raises: without
    # facts the plan reads as a sample throughout, which under-claims.
    comment = TestPlan::Output::PlaybookFormatter.new(
      parsed:, kit_facts: TestPlan::Playbook::KitFacts.load_file(kit_facts_path),
      manifest: read_manifest.call, **options
    ).render
  elsif variant == TestPlan::Profile::DEPENDENCY_PLAN
    parsed = TestPlan::Response::DependencyParser.parse_file(json_path)
    comment = TestPlan::Output::DependencyFormatter.new(
      parsed:, manifest: read_manifest.call, **options
    ).render
  else
    parsed = TestPlan::Response::StandardParser.parse_file(json_path)
    comment = TestPlan::Output::StandardFormatter.new(parsed:, **options).render
  end

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
