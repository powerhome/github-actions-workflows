# frozen_string_literal: true

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "rspec/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

ACTION_ROOT = File.expand_path("..", __dir__)

# Provider adapters and the comment client live beside this action, shared with
# agentic-pr-review, and action.yml reaches them through ../shared.
SHARED_ROOT = File.expand_path("../../shared", __dir__)
