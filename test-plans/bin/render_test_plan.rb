#!/usr/bin/env ruby

require_relative "../lib/test_plan/formatter"
require_relative "../lib/test_plan/parser"
require_relative "../lib/test_plan/dependency/formatter"
require_relative "../lib/test_plan/dependency/parser"
require_relative "../lib/test_plan/playbook/formatter"
require_relative "../lib/test_plan/playbook/kit_facts"
require_relative "../lib/test_plan/playbook/parser"
require_relative "../lib/test_plan/variant"

begin
  json_path = ENV.fetch("TEST_PLAN_JSON_PATH")
  comment_path = ENV.fetch("TEST_PLAN_COMMENT_PATH")
  pull_request_title = ENV.fetch("PULL_REQUEST_TITLE", "")
  profile_name = ENV.fetch("TEST_PLAN_PROFILE_NAME", "Test Plan")
  generation_warning = ENV.fetch("TEST_PLAN_GENERATION_WARNING", "")

  # The same choice the provider step was given, so the plan is rendered in the shape it
  # was asked for rather than in whichever one the response happens to resemble.
  variant = ENV["TEST_PLAN_VARIANT"].to_s
  kit_facts_path = ENV.fetch("PLAYBOOK_KIT_FACTS_PATH")

  options = {
    pull_request_title: pull_request_title,
    profile_name: profile_name,
    generation_warning: generation_warning,
  }

  if variant == TestPlan::Variant::PLAYBOOK
    parsed = TestPlan::Playbook::Parser.parse_file(json_path)
    manifest = JSON.parse(File.read(ENV.fetch("DEPENDENCY_DELTA_MANIFEST_PATH"), encoding: Encoding::UTF_8))
    # Coverage wording comes from what the action counted, not from what the provider
    # reported. KitFacts.load_file never raises: a plan rendered without facts reads as a
    # sample throughout, which under-claims rather than overstating.
    comment = TestPlan::Playbook::Formatter.new(
      parsed: parsed, kit_facts: TestPlan::Playbook::KitFacts.load_file(kit_facts_path),
      manifest: manifest, **options
    ).render
  elsif variant == TestPlan::Variant::DEPENDENCY
    parsed = TestPlan::Dependency::Parser.parse_file(json_path)
    manifest_path = ENV.fetch("DEPENDENCY_DELTA_MANIFEST_PATH")
    manifest = JSON.parse(File.read(manifest_path, encoding: Encoding::UTF_8))
    comment = TestPlan::Dependency::Formatter.new(parsed: parsed, manifest: manifest, **options).render
  else
    parsed = TestPlan::Parser.parse_file(json_path)
    comment = TestPlan::Formatter.new(parsed: parsed, **options).render
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
