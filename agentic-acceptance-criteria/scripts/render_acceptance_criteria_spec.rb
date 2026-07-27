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

RSpec.describe "render_acceptance_criteria.rb" do
  let(:script) { File.expand_path("render_acceptance_criteria.rb", __dir__) }

  def run_renderer(input:, directory:)
    json_path = File.join(directory, "input.json")
    comment_path = File.join(directory, "comment.md")
    File.write(json_path, input)

    env = {
      "ACCEPTANCE_CRITERIA_JSON_PATH" => json_path,
      "ACCEPTANCE_CRITERIA_COMMENT_PATH" => comment_path,
      "PULL_REQUEST_NUMBER" => "42",
      "PULL_REQUEST_TITLE" => "Search migration",
    }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script)

    [comment_path, stdout, stderr, status]
  end

  it "renders a provider response to the requested comment path" do
    payload = {
      "permissions" => { "required" => "no", "roles" => [] },
      "feature_areas" => [],
      "regression_tests" => [],
    }

    Dir.mktmpdir do |directory|
      comment_path, stdout, stderr, status = run_renderer(
        input: payload.to_json,
        directory: directory
      )

      expect(status).to be_success
      expect(stdout).to be_empty
      expect(stderr).to include("[acceptance_criteria] Rendered")
      expect(File.read(comment_path)).to include(
        "## ✅ Test Plan: PR #42 — Search migration"
      )
    end
  end

  it "fails clearly when the provider response is not valid JSON" do
    Dir.mktmpdir do |directory|
      comment_path, _stdout, stderr, status = run_renderer(
        input: "not JSON",
        directory: directory
      )

      expect(status).not_to be_success
      expect(stderr).to include("Failed to parse acceptance-criteria JSON")
      expect(File).not_to exist(comment_path)
    end
  end
end
