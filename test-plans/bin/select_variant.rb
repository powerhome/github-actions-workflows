#!/usr/bin/env ruby

require_relative "../lib/test_plan/variant"

begin
  selection = TestPlan::Variant.select(
    prompt_path: ENV.fetch("TEST_PLAN_PROMPT_PATH"),
    playbook_prompt_path: ENV["TEST_PLAN_PLAYBOOK_PROMPT_PATH"].to_s,
    playbook_kits_changed: ENV["PLAYBOOK_KITS_CHANGED"].to_s == "true",
    lockfile_only: ENV["LOCKFILE_ONLY"].to_s == "true"
  )

  File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
    output.puts("name=#{selection.fetch("name")}")
    output.puts("prompt_path=#{selection.fetch("prompt_path")}")
  end

  puts "[test_plan] variant: #{selection.fetch("name").empty? ? "default" : selection.fetch("name")}"
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end
