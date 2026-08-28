#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "open3"
require "rbconfig"
require "rspec/autorun"
require "tmpdir"

RSpec.describe "render_test_plan.rb" do
  let(:script) { File.expand_path("render_test_plan.rb", __dir__) }

  def run_renderer(input:, directory:, warning: "")
    json_path = File.join(directory, "input.json")
    comment_path = File.join(directory, "comment.md")
    File.write(json_path, input)
    env = {
      "TEST_PLAN_JSON_PATH" => json_path,
      "TEST_PLAN_COMMENT_PATH" => comment_path,
      "TEST_PLAN_PROFILE_NAME" => "Cobra Test Plan",
      "TEST_PLAN_GENERATION_WARNING" => warning,
      "PULL_REQUEST_TITLE" => "Search migration",
    }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script)
    [comment_path, stdout, stderr, status]
  end

  let(:payload) do
    {
      "permissions" => {
        "required" => "no",
        "roles" => [],
        "changes" => [],
        "subject_actions" => [],
      },
      "feature_areas" => [],
      "regression_tests" => [],
    }
  end

  it "renders provider JSON to the requested comment path" do
    Dir.mktmpdir do |directory|
      comment_path, stdout, stderr, status = run_renderer(
        input: payload.to_json,
        directory: directory,
        warning: "A dependency delta was unavailable."
      )
      expect(status).to be_success
      expect(stdout).to be_empty
      expect(stderr).to include("[test_plan] Rendered")
      expect(File.read(comment_path)).to include("## ✅ Cobra Test Plan: Search migration")
      expect(File.read(comment_path)).to include("⚠️ A dependency delta was unavailable.")
    end
  end

  it "fails clearly for invalid provider JSON" do
    Dir.mktmpdir do |directory|
      comment_path, _stdout, stderr, status = run_renderer(input: "not JSON", directory: directory)
      expect(status).not_to be_success
      expect(stderr).to include("Failed to parse test-plan JSON")
      expect(File).not_to exist(comment_path)
    end
  end
end
