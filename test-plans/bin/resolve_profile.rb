#!/usr/bin/env ruby

require_relative "../lib/test_plan/profile"

begin
  action_root = ENV.fetch("TEST_PLAN_ACTION_ROOT")
  profile_id = ENV.fetch("TEST_PLAN_PROFILE")
  output_path = ENV.fetch("GITHUB_OUTPUT")
  profile = TestPlan::Profile.load(action_root: action_root, profile_id: profile_id)

  File.open(output_path, "a", encoding: Encoding::UTF_8) do |output|
    profile.to_h.each do |key, value|
      output.puts("#{key}=#{value}")
    end
  end
rescue JSON::ParserError => e
  warn "Invalid test-plan profile JSON: #{e.message}"
  exit 1
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end
