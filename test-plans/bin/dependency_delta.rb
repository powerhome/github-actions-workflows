#!/usr/bin/env ruby

require_relative "../lib/test_plan/dependency_delta"

begin
  TestPlan::DependencyDelta::Command.new.run
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn "Dependency delta generation failed: #{e.message}"
  exit 1
end
